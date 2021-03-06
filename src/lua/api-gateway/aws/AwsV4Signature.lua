--
-- Created by IntelliJ IDEA.
-- User: ddascal
-- Date: 15/05/14
-- Time: 15:09
--
-- Implements the new Version 4 HMAC authorization.
--
local resty_sha256 = require "resty.sha256"
local str = require "resty.string"
local resty_hmac = require "api-gateway.resty.hmac"

local HmacAuthV4Handler = {}

function HmacAuthV4Handler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if ( o ~= nil) then
        self.aws_endpoint = o.aws_endpoint
        self.aws_service = o.aws_service
        self.aws_region = o.aws_region
        self.aws_secret_key = o.aws_secret_key
        self.aws_access_key = o.aws_access_key
        ---
        -- Whether to double url-encode the resource path when constructing the
        -- canonical request. By default, double url-encoding is true.
        -- Different sigv4 services seem to be inconsistent on this. So for
        -- services that want to suppress this, they should set it to false.
        self.doubleUrlEncode = o.doubleUrlEncode or true
        self.token = o.token
        self.private = o.private or false
    end
    -- set amazon formatted dates
    local utc = ngx.utctime()
    self.aws_date_short = string.gsub(string.sub(utc, 1, 10),"-","")
    self.aws_date = self.aws_date_short .. 'T' .. string.gsub(string.sub(utc, 12),":","") .. 'Z'
    return o
end

local function _sign_sha256_FFI(key, msg, raw)
    local hmac_sha256 = resty_hmac:new()
    local digest = hmac_sha256:digest("sha256",key, msg, raw)
    return digest
end


local function _sha256_hex(msg)
    local sha256 = resty_sha256:new()
    sha256:update(msg)
    return str.to_hex(sha256:final())
end

local _sign = _sign_sha256_FFI
local _hash = _sha256_hex

local function get_hashed_canonical_request(method, uri, querystring, headers, requestPayload)
    local hash = method .. '\n' ..
                 uri .. '\n' ..
                (querystring or "") .. '\n'
    -- add canonicalHeaders
    local canonicalHeaders = ""
    local signedHeaders = ""
    for _, p in ipairs(headers) do
        local h_n, h_v = p[1], p[2]
        -- todo: trim and lowercase
        canonicalHeaders = canonicalHeaders .. h_n .. ":" .. h_v .. "\n"
        signedHeaders = signedHeaders .. h_n .. ";"
    end
    --remove the last ";" from the signedHeaders
    signedHeaders = string.sub(signedHeaders, 1, -2)

    hash = hash .. canonicalHeaders .. "\n"
            .. signedHeaders .. "\n"

    requestPayloadHash = _hash(requestPayload or "")
    hash = hash .. requestPayloadHash

    ngx.log(ngx.DEBUG, "Canonical String to Sign is:\n" .. hash)

    local final_hash = _hash(hash)
    ngx.log(ngx.DEBUG, "Canonical String HASHED is:\n" .. final_hash .. "\n")
    return final_hash, signedHeaders, requestPayloadHash
end

local function get_string_to_sign(algorithm, request_date, credential_scope, hashed_canonical_request)
    local s = algorithm .. "\n" .. request_date .. "\n" .. credential_scope .. "\n" .. hashed_canonical_request
    ngx.log(ngx.DEBUG, "String-to-Sign is:\n" .. s)
    return s
end

local function get_derived_signing_key(aws_secret_key, date, region, service )
    local kDate = _sign("AWS4" .. aws_secret_key, date, true )
    local kRegion = _sign(kDate, region, true)
    local kService = _sign(kRegion, service, true)
    local kSigning = _sign(kService, "aws4_request", true)

    return kSigning
end

local function urlEncode(inputString)
        if (inputString) then
            inputString = string.gsub (inputString, "\n", "\r\n")
            inputString = string.gsub (inputString, "([^%w %-%_%.%~])",
                function (c) return string.format ("%%%02X", string.byte(c)) end)
            inputString = ngx.re.gsub (inputString, " ", "+", "ijo")
            -- AWS workarounds following Java SDK
            -- see https://github.com/aws/aws-sdk-java/blob/master/aws-java-sdk-core/src/main/java/com/amazonaws/util/SdkHttpUtils.java#L80-87
            -- replace '+' ( %2B ) with ( %20 )
            inputString = ngx.re.gsub(inputString, "%2B", "%20", "ijo")
            -- replace %2F with "/"
            inputString = ngx.re.gsub(inputString, "%2F", "/", "ijo")
            -- replace %7E with "~"
            inputString = ngx.re.gsub(inputString, "%7E", "~", "ijo")
        end
        return inputString
        --[[local s = ngx.escape_uri(inputString)
        -- replace '+' ( %2B ) with ( %20 )
        s = ngx.re.gsub(s, "%2B", "%20", "ijo")
        -- replace "," with %2C
        s = ngx.re.gsub(s, ",", "%2C", "ijo")
        return s]]
end

local function getTableIterator(uri_args, urlParameterKeys)
    -- use the keys to get the values out of the uri_args table in alphabetical order
    local i = 0
    local keyValueIterator = function ()
        i = i + 1
        if urlParameterKeys[i] == nil then
            return nil
        end
        return urlParameterKeys[i], uri_args[urlParameterKeys[i]]
    end
    return keyValueIterator
end

function HmacAuthV4Handler:formatQueryString(uri_args)
    local uri = ""

    local urlParameterKeys = {}
    -- insert all the url parameter keys into array
    for n in pairs(uri_args) do
        table.insert(urlParameterKeys, n)
    end
    -- sort the keys
    table.sort(urlParameterKeys)

    local iterator = getTableIterator(uri_args, urlParameterKeys)

    for param_key, param_value in iterator do
        if type(param_value) ~= "string" then
            uri = uri .. urlEncode(param_key) .. "=&"
        else
            uri = uri .. urlEncode(param_key) .. "=" .. urlEncode(param_value) .. "&"
        end
    end
    --remove the last "&" from the signedHeaders
    uri = string.sub(uri, 1, -2)
    return uri
end

function HmacAuthV4Handler:getSignature(http_method, request_uri, uri_arg_table, request_payload, host_override)
    local uri_args = self:formatQueryString(uri_arg_table)
    local utc = ngx.utctime()
    local date1 = self.aws_date_short
    local date2 = self.aws_date
    local host = self.aws_endpoint
    if host_override ~= nil then
        host = host_override
    end

    local headers = {}
    table.insert(headers, {"host", host})
    if (self.private == true) then
        table.insert(headers, {"x-amz-acl", "private"})
    end
    table.insert(headers, {"x-amz-date", date2})
    if self.token ~= nil then
        table.insert(headers, {"x-amz-security-token", self.token})
    end

    local encoded_request_uri = request_uri
    if (self.doubleUrlEncode == true) then
        encoded_request_uri = urlEncode(request_uri)
    end
    -- ensure parameters in query string are in order
    local hashed_canonical_request, signed_headers, request_payload_hash = get_hashed_canonical_request(
        http_method, encoded_request_uri,
        uri_args,
        headers, request_payload)
    local sign = _sign( get_derived_signing_key( self.aws_secret_key,
        date1,
        self.aws_region,
        self.aws_service),
        get_string_to_sign("AWS4-HMAC-SHA256",
            date2,
            date1 .. "/" .. self.aws_region .. "/" .. self.aws_service .. "/aws4_request",
            hashed_canonical_request) )
    return sign, signed_headers, request_payload_hash
end

function HmacAuthV4Handler:getSignatureWithHeaders(http_method, request_uri, uri_arg_table, request_payload, headers, date, short_date)
    local uri_args = self:formatQueryString(uri_arg_table)

    -- ensure parameters in query string are in order
    local hashed_canonical_request, signed_headers, request_payload_hash = get_hashed_canonical_request(
        http_method, request_uri,
        uri_args,
        headers, request_payload)
    local sign = _sign(get_derived_signing_key(self.aws_secret_key,
        short_date,
        self.aws_region,
        self.aws_service),
        get_string_to_sign("AWS4-HMAC-SHA256",
            date,
            short_date .. "/" .. self.aws_region .. "/" .. self.aws_service .. "/aws4_request",
            hashed_canonical_request))
    return sign, signed_headers, request_payload_hash
end

function HmacAuthV4Handler:getAuthorizationHeader(http_method, request_uri, uri_arg_table, request_payload, host_override)
    local auth_signature, signed_headers, request_payload_hash = self:getSignature(http_method, request_uri, uri_arg_table, request_payload, host_override)
    local authHeader = "AWS4-HMAC-SHA256 Credential=" .. self.aws_access_key.."/" .. self.aws_date_short .. "/" .. self.aws_region
           .."/" .. self.aws_service.."/aws4_request,SignedHeaders="..signed_headers..",Signature="..auth_signature
    return authHeader, request_payload_hash
end

return HmacAuthV4Handler









