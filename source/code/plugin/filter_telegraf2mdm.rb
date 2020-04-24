# Copyright (c) Microsoft Corporation.  All rights reserved.

# frozen_string_literal: true

module Fluent
  require "logger"
  require "yajl/json_gem"
  require_relative "oms_common"
  # require_relative "CustomMetricsUtils"
  require_relative "kubelet_utils"
  require_relative "MdmMetricsGenerator"
  require_relative "constants"

  class Telegraf2MdmFilter < Filter
    Fluent::Plugin.register_filter("filter_telegraf2mdm", self)

    config_param :enable_log, :integer, :default => 0
    config_param :log_path, :string, :default => "/var/opt/microsoft/docker-cimprov/log/filter_telegraf2mdm.log"
    config_param :custom_metrics_azure_regions, :string

    @process_incoming_stream = true

    def initialize
      super
    end

    def configure(conf)
      super
      @log = nil

      if @enable_log
        @log = Logger.new(@log_path, 1, 5000000)
        @log.debug { "Starting filter_telegraf2mdm plugin" }
      end
    end

    def start
      super
      begin
        @process_incoming_stream = CustomMetricsUtils.check_custom_metrics_availability(@custom_metrics_azure_regions)
        @log.debug "After check_custom_metrics_availability process_incoming_stream #{@process_incoming_stream}"
        @@telegrafMetricsTelemetryTimeTracker = DateTime.now.to_time.to_i
      rescue => errorStr
        @log.info "Error initializing plugin #{errorStr}"
      end
    end

    def shutdown
      super
    end

    def filter(tag, time, record)
      begin
        # @log.info "tag: #{tag}, time: #{time}, record: #{record}"
        if !record["name"].nil? && record["name"].downcase == Constants::TELEGRAF_DISK_METRICS
          return MdmMetricsGenerator.getDiskUsageMetricRecords(record)
        end
        if !record["name"].nil? && record["name"].downcase == Constants::TELEGRAF_NETWORK_METRICS
          return MdmMetricsGenerator.getNetworkErrorMetricRecords(record)
        end
        if !record["name"].nil? && record["name"].downcase == Constants::TELEGRAF_PROMETHEUS_METRICS
          return MdmMetricsGenerator.getPrometheusMetricRecords(record)
        end
        return []
      rescue Exception => errorStr
        @log.info "Error processing telegraf record Exception: #{errorStr}"
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
        return [] #return empty array if we ran into any errors
      end
    end

    def filter_stream(tag, es)
      new_es = MultiEventStream.new
      begin
        # ensure_cpu_memory_capacity_set
        # Getting container limits hash
        # @containerCpuLimitHash, @containerMemoryLimitHash, @containerResourceDimensionHash = KubeletUtils.get_all_container_limits

        es.each { |time, record|
          filtered_records = filter(tag, time, record)
          filtered_records.each { |filtered_record|
            new_es.add(time, filtered_record) if filtered_record
          } if filtered_records
        }

        #Send heartbeat telemetry if flush interval is exceeded
        timeDifference = (DateTime.now.to_time.to_i - @@telegrafMetricsTelemetryTimeTracker).abs
        timeDifferenceInMinutes = timeDifference / 60
        if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES)
          properties = {}
          ApplicationInsightsUtility.sendCustomEvent(Constants::TELEGRAF_METRICS_HEART_BEAT_EVENT, properties)
          @@telegrafMetricsTelemetryTimeTracker = DateTime.now.to_time.to_i
        end
      rescue => e
        @log.info "Error in filter_stream #{e.message}"
      end
      new_es
    end
  end
end