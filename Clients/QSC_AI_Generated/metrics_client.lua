--[[
AV-System-Metrics Q-SYS Lua client.

Copy this file into a Q-SYS Lua Module named "metrics_client", then require it
from a Control Script:

    local Metrics = require("metrics_client")

    metrics = Metrics.new({
        processor_name = "boardroom-qsys-core",
        uri_type = "aws_lambda",
        uri = "https://example.lambda-url.us-west-1.on.aws/",
        bearer_token = "change-me-long-random-token"
    })

    metrics:trace("System Initialized")
]]

local rapidjson = require("rapidjson")

local Metrics = {}
Metrics.__index = Metrics
Metrics.__version__ = "2.1.2"

local MAX_BATCH_SIZE = 25

local function default_logger(message, level)
    print(string.format("%s: %s", string.upper(tostring(level or "info")), tostring(message)))
end

local function is_blank(value)
    return value == nil or tostring(value) == ""
end

local function current_seconds()
    if Timer ~= nil and Timer.Now ~= nil then
        local ok, value = pcall(Timer.Now)
        if ok and type(value) == "number" then
            return value
        end
    end

    if os ~= nil and os.time ~= nil then
        return os.time()
    end

    return 0
end

local function utc_timestamp()
    if os ~= nil and os.date ~= nil then
        local ok, value = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ")
        if ok and type(value) == "string" then
            return value
        end

        ok, value = pcall(os.date, "%Y-%m-%dT%H:%M:%SZ")
        if ok and type(value) == "string" then
            return value
        end
    end

    return "1970-01-01T00:00:00Z"
end

local function get_setting(settings, snake_name, camel_name, default_value)
    local value = settings[snake_name]
    if value == nil and camel_name ~= nil then
        value = settings[camel_name]
    end
    if value == nil then
        return default_value
    end
    return value
end

local function get_number(value, default_value)
    local number_value = tonumber(value)
    if number_value == nil then
        return default_value
    end
    return number_value
end

function Metrics.new(logger_or_settings, processor_name, uri_type, uri, bearer_token,
                     batch_size, flush_interval, max_cache_size,
                     failure_drop_message_threshold, failure_drop_time_threshold,
                     request_timeout)
    local self = setmetatable({}, Metrics)

    if type(logger_or_settings) == "table" then
        local settings = logger_or_settings
        self.logger = get_setting(settings, "logger", nil, default_logger)
        self.processor_name = get_setting(settings, "processor_name", "processorName", nil)
        if self.processor_name == nil then
            self.processor_name = get_setting(settings, "client_name", "clientName", settings.clientname)
        end
        self.uri_type = string.lower(tostring(get_setting(settings, "uri_type", "uriType", "")))
        self.uri = get_setting(settings, "uri", nil, nil)
        self.bearer_token = get_setting(settings, "bearer_token", "bearerToken", nil)
        self.batch_size = get_number(get_setting(settings, "batch_size", "batchSize", 20), 20)
        self.flush_interval = get_number(get_setting(settings, "flush_interval", "flushInterval", 10), 10)
        self.max_cache_size = get_number(get_setting(settings, "max_cache_size", "maxCacheSize", 250), 250)
        self.failure_drop_message_threshold = get_number(get_setting(settings, "failure_drop_message_threshold", "failureDropMessageThreshold", 100), 100)
        self.failure_drop_time_threshold = get_number(get_setting(settings, "failure_drop_time_threshold", "failureDropTimeThreshold", 300), 300)
        self.request_timeout = get_number(get_setting(settings, "request_timeout", "requestTimeout", 10), 10)
    else
        self.logger = logger_or_settings or default_logger
        self.processor_name = processor_name
        self.uri_type = string.lower(tostring(uri_type or ""))
        self.uri = uri
        self.bearer_token = bearer_token
        self.batch_size = get_number(batch_size or 20, 20)
        self.flush_interval = get_number(flush_interval or 10, 10)
        self.max_cache_size = get_number(max_cache_size or 250, 250)
        self.failure_drop_message_threshold = get_number(failure_drop_message_threshold or 100, 100)
        self.failure_drop_time_threshold = get_number(failure_drop_time_threshold or 300, 300)
        self.request_timeout = get_number(request_timeout or 10, 10)
    end

    self._metric_cache = {}
    self._flush_scheduled = false
    self._sending = false
    self._failed_message_count = 0
    self._first_failure_time = nil

    self:_validate_settings()
    self:_log("Metrics settings validated successfully", "info")

    return self
end

Metrics.New = Metrics.new

function Metrics:_validate_settings()
    if Timer == nil or Timer.CallAfter == nil then
        error("Q-SYS Timer.CallAfter is required")
    end

    if HttpClient == nil or HttpClient.Upload == nil then
        error("Q-SYS HttpClient.Upload is required")
    end

    if self.uri_type ~= "aws_lambda" and self.uri_type ~= "self-hosted" and self.uri_type ~= "aws_api_gateway" then
        error("uri_type must be one of: aws_lambda, self-hosted, aws_api_gateway")
    end

    if self.uri_type == "aws_api_gateway" then
        error("aws_api_gateway is not implemented yet for AV-System-Metrics")
    end

    if is_blank(self.processor_name) then
        error("processor_name can not be empty")
    end

    if is_blank(self.uri) then
        error("uri can not be empty")
    end

    if is_blank(self.bearer_token) then
        error("bearer_token can not be empty")
    end

    if self.batch_size < 1 or self.batch_size > MAX_BATCH_SIZE then
        error("batch_size must be between 1 and 25")
    end

    if self.flush_interval <= 0 then
        error("flush_interval must be greater than 0")
    end

    if self.max_cache_size < self.batch_size then
        error("max_cache_size must be greater than or equal to batch_size")
    end

    if self.failure_drop_message_threshold < 1 then
        error("failure_drop_message_threshold must be at least 1")
    end

    if self.failure_drop_time_threshold <= 0 then
        error("failure_drop_time_threshold must be greater than 0")
    end

    if self.request_timeout <= 0 then
        error("request_timeout must be greater than 0")
    end
end

function Metrics:_log(message, level)
    if type(self.logger) == "function" then
        pcall(self.logger, tostring(message), level or "info")
    else
        default_logger(message, level)
    end
end

function Metrics:_can_drop_oldest_metrics()
    if self._failed_message_count >= self.failure_drop_message_threshold then
        return true
    end

    if self._first_failure_time ~= nil then
        return (current_seconds() - self._first_failure_time) >= self.failure_drop_time_threshold
    end

    return false
end

function Metrics:_trim_cache_if_allowed()
    if #self._metric_cache <= self.max_cache_size then
        return
    end

    if not self:_can_drop_oldest_metrics() then
        self:_log(
            string.format(
                "Metric cache size is %d, max is %d, but dropping is not allowed yet.",
                #self._metric_cache,
                self.max_cache_size
            ),
            "warning"
        )
        return
    end

    local drop_count = #self._metric_cache - self.max_cache_size
    for _ = 1, drop_count do
        table.remove(self._metric_cache, 1)
    end

    self:_log(
        string.format(
            "Dropping %d oldest cached metrics after send failures. Failed message count: %d",
            drop_count,
            self._failed_message_count
        ),
        "warning"
    )
end

function Metrics:_cache_metric(action, metric_name)
    table.insert(self._metric_cache, {
        clientname = tostring(self.processor_name),
        timestamp = utc_timestamp(),
        metric = tostring(metric_name or ""),
        action = tostring(action or "")
    })

    self:_trim_cache_if_allowed()

    if #self._metric_cache >= self.batch_size then
        self:flush()
    else
        self:_schedule_flush()
    end
end

function Metrics:_schedule_flush()
    if self._flush_scheduled then
        return
    end

    self._flush_scheduled = true

    Timer.CallAfter(function()
        self._flush_scheduled = false
        self:flush()
    end, self.flush_interval)
end

function Metrics:_take_batch()
    local count = math.min(self.batch_size, #self._metric_cache)
    local batch = {}

    for i = 1, count do
        batch[i] = self._metric_cache[i]
    end

    for _ = 1, count do
        table.remove(self._metric_cache, 1)
    end

    return batch
end

function Metrics:flush()
    if self._sending then
        self:_schedule_flush()
        return
    end

    if #self._metric_cache == 0 then
        return
    end

    self._sending = true
    self:_send_batch(self:_take_batch())
end

Metrics.Flush = Metrics.flush

function Metrics:_send_batch(messages)
    local payload, encode_error = rapidjson.encode({ messages = messages })
    if payload == nil then
        self:_log("Could not encode metrics payload: " .. tostring(encode_error), "error")
        self:_record_send_failure(messages)
        self:_finish_send()
        return
    end

    local ok, upload_error = pcall(function()
        HttpClient.Upload {
            Url = self.uri,
            Method = "POST",
            Data = payload,
            Headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. tostring(self.bearer_token)
            },
            Timeout = self.request_timeout,
            EventHandler = function(_, code, data, err)
                self:_handle_response(code, data, err, messages)
            end
        }
    end)

    if not ok then
        self:_log(upload_error, "error")
        self:_record_send_failure(messages)
        self:_finish_send()
    end
end

function Metrics:_handle_response(code, data, err, messages)
    local status_code = tonumber(code) or 0

    if status_code >= 200 and status_code < 300 then
        self:_log("Server response status: " .. tostring(status_code), "info")
        if data ~= nil and tostring(data) ~= "" then
            self:_log(data, "info")
        end

        local ack_ok, ack_error = self:_validate_server_ack(data, #messages)
        if ack_ok then
            self:_reset_failure_state()
        else
            self:_log(
                string.format(
                    "Server acknowledgement validation failed: %s. Will retry %d metrics.",
                    tostring(ack_error),
                    #messages
                ),
                "error"
            )
            self:_record_send_failure(messages)
        end

        self:_finish_send()
        return
    end

    if status_code == 429 then
        self:_log(
            string.format("Server rate limited request (429). Will retry %d metrics.", #messages),
            "warning"
        )
        self:_record_send_failure(messages)
    elseif status_code >= 400 and status_code < 500 then
        self:_log(
            string.format("Permanent client error %d. Dropping %d metrics.", status_code, #messages),
            "error"
        )
        if data ~= nil and tostring(data) ~= "" then
            self:_log(data, "error")
        end
    elseif status_code >= 500 then
        self:_log(
            string.format("Server error %d. Will retry %d metrics.", status_code, #messages),
            "error"
        )
        self:_record_send_failure(messages)
    else
        self:_log(
            string.format("HTTP request failed. Code=%s Error=%s. Will retry %d metrics.", tostring(code), tostring(err), #messages),
            "error"
        )
        self:_record_send_failure(messages)
    end

    self:_finish_send()
end

function Metrics:_validate_server_ack(data, expected_count)
    if data == nil or tostring(data) == "" then
        return false, "empty response body"
    end

    local decode_ok, ack, decode_error = pcall(rapidjson.decode, tostring(data))
    if not decode_ok then
        return false, "invalid JSON response: " .. tostring(ack)
    end

    if ack == nil then
        return false, "invalid JSON response: " .. tostring(decode_error)
    end

    if type(ack) ~= "table" then
        return false, "response JSON was not an object"
    end

    if ack.ok ~= true then
        return false, "response ok was not true"
    end

    if type(ack.count) ~= "number" then
        return false, "response count was not a number"
    end

    if ack.count ~= expected_count then
        return false, string.format(
            "response count %s did not match sent count %d",
            tostring(ack.count),
            expected_count
        )
    end

    return true, nil
end

function Metrics:_finish_send()
    self._sending = false

    if #self._metric_cache > 0 then
        self:_schedule_flush()
    end
end

function Metrics:_record_send_failure(messages)
    if self._first_failure_time == nil then
        self._first_failure_time = current_seconds()
    end

    self._failed_message_count = self._failed_message_count + #messages

    for i = #messages, 1, -1 do
        table.insert(self._metric_cache, 1, messages[i])
    end

    self:_trim_cache_if_allowed()
end

function Metrics:_reset_failure_state()
    self._failed_message_count = 0
    self._first_failure_time = nil
end

function Metrics:start(metric_name)
    self:_cache_metric("Started", metric_name)
end

Metrics.Start = Metrics.start

function Metrics:stop(metric_name)
    self:_cache_metric("Stopped", metric_name)
end

Metrics.Stop = Metrics.stop

function Metrics:trace(metric_name)
    self:_cache_metric("Trace", metric_name)
end

Metrics.Trace = Metrics.trace

function Metrics:custom(action, metric_name)
    self:_cache_metric(action, metric_name)
end

Metrics.Custom = Metrics.custom

return Metrics
