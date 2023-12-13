local config = require "config"
local redisCli = require "redisCli"
local loggerFactory = require "loggerFactory"
local cc = require "cc"
local cjson = require "cjson.safe"
local stringutf8 = require "stringutf8"

local md5 = ngx.md5
local toUpper = string.upper
local concat = table.concat

local _M = {}

local logPath = config.get("logPath")
local rulePath = config.get("rulePath")

local dict_hits = ngx.shared.dict_config_rules_hits
local RULES_HIT_PREFIX = "waf_rules_hits:"
local RULES_HIT_EXPTIME = 60

local function writeLog(ruleType, data, rule, action)
    if config.isAttackLogOn then
        local realIp = ngx.ctx.ip
        local country = ngx.ctx.geoip.country
        local province = ngx.ctx.geoip.province
        local city = ngx.ctx.geoip.city
        local method = ngx.req.get_method()
        local url = ngx.var.request_uri
        local ua = ngx.ctx.ua
        local host = ngx.var.server_name
        local protocol = ngx.var.server_protocol
        local time = ngx.localtime()

        if config.isJsonFormatLogOn then
            local logTable = {
                attack_type = ruleType,
                remote_addr = realIp,
                geoip_country = country,
                geoip_province = province,
                geoip_city = city,
                attack_time = time,
                http_method = method,
                server = host,
                request_uri = url,
                request_protocol = protocol,
                request_data = data or '',
                user_agent = ua,
                hit_rule = rule,
                action = action
            }
            local logStr, err = cjson.encode(logTable)
            if logStr then
                local hostLogger = loggerFactory.getLogger(logPath, host, true)
                hostLogger:log(logStr .. '\n')
            else
                ngx.log(ngx.ERR, "failed to encode json: ", err)
            end
        else
            local address = country .. province .. city
            address = stringutf8.defaultIfBlank(address, '-')
            ua = stringutf8.defaultIfBlank(ua, '-')
            data = stringutf8.defaultIfBlank(data, '-')

            local logStr = concat({ruleType, realIp, address, "[" .. time .. "]", '"' .. method, host, url, protocol .. '"', data, '"' .. ua .. '"', '"' .. rule .. '"', action},' ')
            local hostLogger = loggerFactory.getLogger(logPath, host, true)
            hostLogger:log(logStr .. '\n')
        end

    end
end

local function deny(status)
    if config.isProtectionMode then
        local statusCode = ngx.HTTP_FORBIDDEN
        if status then
            statusCode = status
        end

        ngx.status = statusCode
        return ngx.exit(ngx.status)
    end
end

local function redirect()
    if config.isProtectionMode then
        if config.isRedirectOn then
            local original_args = ngx.req.get_uri_args()
            local res = ngx.location.capture("/honeypot", { 
                method = ngx.HTTP_GET, 
                args = original_args, 
                ctx = { header = ngx.req.get_headers() } 
            })

            if res.status == ngx.HTTP_OK then
                ngx.say(res.body)
                ngx.exit(ngx.HTTP_OK)
            else
                ngx.say("request failed")
                ngx.exit(res.status)
            end
        end

        return deny()
    end
end

-- block ip
function _M.blockIp(ip, ruleTab)
    if toUpper(ruleTab.autoIpBlock) == "ON" and ip then
        local ok, err, needLog = nil, nil, nil

        if config.isRedisOn then
            local key = "black_ip:" .. ip

            local red, err1 = redisCli.getRedisConn()
            if not red then
                return nil, err1
            end

            local exists = red:exists(key)
            if exists == 0 then
                ok, err = red:set(key, 1)
                if ok then
                    needLog = true
                else
                    ngx.log(ngx.ERR, "failed to set redis key " .. key, err)
                end
            end

            if ruleTab.ipBlockTimeout > 0 then
                ok, err = red:expire(key, ruleTab.ipBlockTimeout)
                if not ok then
                    ngx.log(ngx.ERR, "failed to expire redis key " .. key, err)
                end
            end

            redisCli.closeRedisConn(red)
        else
            local blackip = ngx.shared.dict_blackip
            local exists = blackip:get(ip)
            if not exists then
                ok, err = blackip:set(ip, 1, ruleTab.ipBlockTimeout)
                if ok then
                    needLog = true
                else
                    ngx.log(ngx.ERR, "failed to set key " .. ip, err)
                end
            elseif ruleTab.ipBlockTimeout > 0 then
                ok, err = blackip:expire(ip, ruleTab.ipBlockTimeout)
                if not ok then
                    ngx.log(ngx.ERR, "failed to expire key " .. ip, err)
                end
            end
        end

        if needLog then
            local hostLogger = loggerFactory.getLogger(logPath .. "ipBlock.log", 'ipBlock', false)
            hostLogger:log(concat({ngx.localtime(), ip, ruleTab.ruleType, ruleTab.ipBlockTimeout .. 's'}, ' ') .. "\n")

            if ruleTab.ipBlockTimeout == 0 then
                local ipBlackLogger = loggerFactory.getLogger(rulePath .. "ipBlackList", 'ipBlack', false)
                ipBlackLogger:log(ip .. "\n")
            end
        end

        return ok
    end
end

local function hit(ruleTable)
    if config.isRulesSortOn then
        local ruleMd5Str = md5(ruleTable.rule)
        local ruleType = ruleTable.ruleType
        local key = RULES_HIT_PREFIX .. ruleType .. '_' .. ruleMd5Str
        local key_total = RULES_HIT_PREFIX .. ruleType .. '_total_' .. ruleMd5Str
        local newHits = nil
        local newTotalHits = nil

        if config.isRedisOn then
            local count = redisCli.redisGet(key)
            if not count then
                redisCli.redisSet(key, 1, RULES_HIT_EXPTIME)
            else
                newHits, _ = redisCli.redisIncr(key)
            end
            newTotalHits, _ = redisCli.redisIncr(key_total)
        else
            newHits, _ = dict_hits:incr(key, 1, 0, RULES_HIT_EXPTIME)
            newTotalHits, _ = dict_hits:incr(key_total, 1, 0)
        end

        ruleTable.hits = newHits or 1
        ruleTable.totalHits = newTotalHits or 1
    end
end

function _M.doAction(ruleTable, data, ruleType, status)
    local rule = ruleTable.rule
    local action = toUpper(ruleTable.action)
    if ruleType == nil then
        ruleType = ruleTable.ruleType
    else
        ruleTable.ruleType = ruleType
    end

    hit(ruleTable)
    ngx.ctx.ruleTable = ruleTable

    if action == "ALLOW" then
        writeLog(ruleType, data, rule, "ALLOW")
    elseif action == "DENY" then
        writeLog(ruleType, data, rule, "DENY")
        deny(status)
    elseif action == "REDIRECT" then
        writeLog(ruleType, data, rule, "REDIRECT")
        redirect()
    elseif action == "REDIRECT_302" then
        writeLog(ruleType, data, rule, "REDIRECT_302")
        cc.redirect302()
    elseif action == "REDIRECT_JS" then
        writeLog(ruleType, data, rule, "REDIRECT_JS")
        cc.redirectJS()
    else
        writeLog(ruleType, data, rule, "REDIRECT")
        redirect()
    end
end

return _M
