# SPDX-License-Identifier: Apache-2.0
#
# The fluent-plugin-opensearch Contributors require contributions made to
# this file be licensed under the Apache-2.0 license or a
# compatible open source license.
#
# Modifications Copyright fluent-plugin-opensearch Contributors. See
# GitHub history for details.
#
# Licensed to Uken Inc. under one or more contributor
# license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Uken Inc. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

require 'date'
require 'excon'
require 'opensearch'
require 'set'
require 'json'
require 'uri'
require 'base64'
begin
  require 'strptime'
rescue LoadError
end
require 'resolv'

require 'fluent/plugin/output'
require 'fluent/event'
require 'fluent/error'
require 'fluent/time'
require 'fluent/unique_id'
require 'fluent/log-ext'
require 'zlib'
require_relative 'opensearch_constants'
require_relative 'opensearch_error'
require_relative 'opensearch_error_handler'
require_relative 'opensearch_index_template'
require_relative 'opensearch_tls'
require_relative 'opensearch_fallback_selector'
begin
  require_relative 'oj_serializer'
rescue LoadError
end
require 'aws-sdk-core'
require 'faraday_middleware/aws_sigv4'
require 'faraday/excon'

module Fluent::Plugin
  class OpenSearchOutput < Output
    class RecoverableRequestFailure < StandardError; end
    class UnrecoverableRequestFailure < Fluent::UnrecoverableError; end
    class RetryStreamEmitFailure < StandardError; end

    # MissingIdFieldError is raised for records that do not
    # include the field for the unique record identifier
    class MissingIdFieldError < StandardError; end

    # RetryStreamError privides a stream to be
    # put back in the pipeline for cases where a bulk request
    # failed (e.g some records succeed while others failed)
    class RetryStreamError < StandardError
      attr_reader :retry_stream
      def initialize(retry_stream)
        @retry_stream = retry_stream
      end
    end

    RequestInfo = Struct.new(:host, :index, :target_index, :alias)

    attr_reader :template_names
    attr_reader :ssl_version_options
    attr_reader :compressable_connection
    attr_reader :duration_seconds

    helpers :event_emitter, :compat_parameters, :record_accessor, :timer

    Fluent::Plugin.register_output('opensearch', self)

    DEFAULT_BUFFER_TYPE = "memory"
    DEFAULT_OPENSEARCH_VERSION = 1
    DEFAULT_TYPE_NAME = "_doc".freeze
    DEFAULT_RELOAD_AFTER = -1
    DEFAULT_TARGET_BULK_BYTES = -1
    DEFAULT_POLICY_ID = "logstash-policy"
    DEFAULT_DURATION = "5h"

    config_param :host, :string,  :default => 'localhost'
    config_param :port, :integer, :default => 9200
    config_param :user, :string, :default => nil
    config_param :password, :string, :default => nil, :secret => true
    config_param :path, :string, :default => nil
    config_param :scheme, :enum, :list => [:https, :http], :default => :http
    config_param :hosts, :string, :default => nil
    config_param :target_index_key, :string, :default => nil
    config_param :time_key_format, :string, :default => nil
    config_param :time_precision, :integer, :default => 9
    config_param :include_timestamp, :bool, :default => false
    config_param :logstash_format, :bool, :default => false
    config_param :logstash_prefix, :string, :default => "logstash"
    config_param :logstash_prefix_separator, :string, :default => '-'
    config_param :logstash_dateformat, :string, :default => "%Y.%m.%d"
    config_param :utc_index, :bool, :default => true
    config_param :suppress_type_name, :bool, :default => false
    config_param :index_name, :string, :default => "fluentd"
    config_param :id_key, :string, :default => nil
    config_param :write_operation, :string, :default => "index"
    config_param :parent_key, :string, :default => nil
    config_param :routing_key, :string, :default => nil
    config_param :request_timeout, :time, :default => 5
    config_param :reload_connections, :bool, :default => true
    config_param :reload_on_failure, :bool, :default => false
    config_param :retry_tag, :string, :default=>nil
    config_param :resurrect_after, :time, :default => 60
    config_param :time_key, :string, :default => nil
    config_param :time_key_exclude_timestamp, :bool, :default => false
    config_param :ssl_verify , :bool, :default => true
    config_param :client_key, :string, :default => nil
    config_param :client_cert, :string, :default => nil
    config_param :client_key_pass, :string, :default => nil, :secret => true
    config_param :ca_file, :string, :default => nil
    config_param :remove_keys, :string, :default => nil
    config_param :remove_keys_on_update, :string, :default => ""
    config_param :remove_keys_on_update_key, :string, :default => nil
    config_param :flatten_hashes, :bool, :default => false
    config_param :flatten_hashes_separator, :string, :default => "_"
    config_param :template_name, :string, :default => nil
    config_param :template_file, :string, :default => nil
    config_param :template_overwrite, :bool, :default => false
    config_param :customize_template, :hash, :default => nil
    config_param :index_date_pattern, :string, :default => "now/d"
    config_param :index_separator, :string, :default => "-"
    config_param :application_name, :string, :default => "default"
    config_param :templates, :hash, :default => nil
    config_param :max_retry_putting_template, :integer, :default => 10
    config_param :fail_on_putting_template_retry_exceed, :bool, :default => true
    config_param :fail_on_detecting_os_version_retry_exceed, :bool, :default => true
    config_param :max_retry_get_os_version, :integer, :default => 15
    config_param :include_tag_key, :bool, :default => false
    config_param :tag_key, :string, :default => 'tag'
    config_param :time_parse_error_tag, :string, :default => 'opensearch_plugin.output.time.error'
    config_param :reconnect_on_error, :bool, :default => false
    config_param :pipeline, :string, :default => nil
    config_param :with_transporter_log, :bool, :default => false
    config_param :emit_error_for_missing_id, :bool, :default => false
    config_param :sniffer_class_name, :string, :default => nil
    config_param :selector_class_name, :string, :default => nil
    config_param :reload_after, :integer, :default => DEFAULT_RELOAD_AFTER
    config_param :include_index_in_url, :bool, :default => false
    config_param :http_backend, :enum, list: [:excon, :typhoeus], :default => :excon
    config_param :http_backend_excon_nonblock, :bool, :default => true
    config_param :validate_client_version, :bool, :default => false
    config_param :prefer_oj_serializer, :bool, :default => false
    config_param :unrecoverable_error_types, :array, :default => ["out_of_memory_error", "rejected_execution_exception"]
    config_param :unrecoverable_record_types, :array, :default => ["json_parse_exception"]
    config_param :emit_error_label_event, :bool, :default => true
    config_param :verify_os_version_at_startup, :bool, :default => true
    config_param :default_opensearch_version, :integer, :default => DEFAULT_OPENSEARCH_VERSION
    config_param :log_os_400_reason, :bool, :default => false
    config_param :custom_headers, :hash, :default => {}
    config_param :suppress_doc_wrap, :bool, :default => false
    config_param :ignore_exceptions, :array, :default => [], value_type: :string, :desc => "Ignorable exception list"
    config_param :exception_backup, :bool, :default => true, :desc => "Chunk backup flag when ignore exception occured"
    config_param :bulk_message_request_threshold, :size, :default => DEFAULT_TARGET_BULK_BYTES
    config_param :compression_level, :enum, list: [:no_compression, :best_speed, :best_compression, :default_compression], :default => :no_compression
    config_param :truncate_caches_interval, :time, :default => nil
    config_param :use_legacy_template, :bool, :default => true
    config_param :catch_transport_exception_on_retry, :bool, :default => true
    config_param :target_index_affinity, :bool, :default => false

    config_section :metadata, param_name: :metainfo, multi: false do
      config_param :include_chunk_id, :bool, :default => false
      config_param :chunk_id_key, :string, :default => "chunk_id".freeze
    end

    config_section :endpoint, multi: false do
      config_param :region, :string
      config_param :url do |c|
        c.chomp("/")
      end
      config_param :access_key_id, :string, :default => ""
      config_param :secret_access_key, :string, :default => "", secret: true
      config_param :assume_role_arn, :string, :default => nil
      config_param :ecs_container_credentials_relative_uri, :string, :default => nil #Set with AWS_CONTAINER_CREDENTIALS_RELATIVE_URI environment variable value
      config_param :assume_role_session_name, :string, :default => "fluentd"
      config_param :assume_role_web_identity_token_file, :string, :default => nil
      config_param :sts_credentials_region, :string, :default => nil
      config_param :refresh_credentials_interval, :time, :default => DEFAULT_DURATION
      config_param :aws_service_name, :enum, list: [:es, :aoss], :default => :es
    end

    config_section :buffer do
      config_set_default :@type, DEFAULT_BUFFER_TYPE
      config_set_default :chunk_keys, ['tag']
      config_set_default :timekey_use_utc, true
    end

    include Fluent::OpenSearchIndexTemplate
    include Fluent::Plugin::OpenSearchConstants
    include Fluent::Plugin::OpenSearchTLS

    def initialize
      super

      @duration_seconds = Fluent::Config.time_value(DEFAULT_DURATION)
    end

    ######################################################################################################
    # This creating AWS credentials code part is heavily based on fluent-plugin-aws-elasticsearch-service:
    # https://github.com/atomita/fluent-plugin-aws-elasticsearch-service/blob/master/lib/fluent/plugin/out_aws-elasticsearch-service.rb#L73-L134
    ######################################################################################################
    def aws_credentials(conf)
      credentials = nil
      unless conf[:access_key_id].empty? || conf[:secret_access_key].empty?
        credentials = Aws::Credentials.new(conf[:access_key_id], conf[:secret_access_key])
      else
        if conf[:assume_role_arn].nil?
          aws_container_credentials_relative_uri = conf[:ecs_container_credentials_relative_uri] || ENV["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
          if aws_container_credentials_relative_uri.nil?
            credentials = Aws::SharedCredentials.new({retries: 2}).credentials rescue nil
            credentials ||= Aws::InstanceProfileCredentials.new.credentials rescue nil
            credentials ||= Aws::ECSCredentials.new.credentials
          else
            credentials = Aws::ECSCredentials.new({
                            credential_path: aws_container_credentials_relative_uri
                          }).credentials
          end
        else
          if conf[:assume_role_web_identity_token_file].nil?
            credentials = Aws::AssumeRoleCredentials.new({
                            role_arn: conf[:assume_role_arn],
                            role_session_name: conf[:assume_role_session_name],
                            region: sts_creds_region(conf),
                            duration_seconds: @duration_seconds
                          }).credentials
          else
            credentials = Aws::AssumeRoleWebIdentityCredentials.new({
                            role_arn: conf[:assume_role_arn],
                            web_identity_token_file: conf[:assume_role_web_identity_token_file],
                            region: sts_creds_region(conf),
                            duration_seconds: @duration_seconds
                          }).credentials
          end
        end
      end
      raise "No valid AWS credentials found." unless credentials.set?

      credentials
    end

    def sts_creds_region(conf)
      conf[:sts_credentials_region] || conf[:region]
    end
    ###############################
    # AWS credential part is ended.
    ###############################

    def configure(conf)
      compat_parameters_convert(conf, :buffer)

      super

      if @endpoint
        # here overrides default value of reload_connections to false because
        # AWS Elasticsearch Service doesn't return addresses of nodes and Elasticsearch client
        # fails to reload connections properly. This ends up "temporarily failed to flush the buffer"
        # error repeating forever. See this discussion for details:
        # https://discuss.elastic.co/t/elasitcsearch-ruby-raises-cannot-get-new-connection-from-pool-error/36252
        @reload_connections = false
      end

      if placeholder_substitution_needed_for_template?
        # nop.
      elsif not @buffer_config.chunk_keys.include? "tag" and
        not @buffer_config.chunk_keys.include? "_index"
        raise Fluent::ConfigError, "'tag' or '_index' in chunk_keys is required."
      end
      @time_parser = create_time_parser
      @backend_options = backend_options
      @ssl_version_options = set_tls_minmax_version_config(@ssl_version, @ssl_max_version, @ssl_min_version)

      if @remove_keys
        @remove_keys = @remove_keys.split(/\s*,\s*/)
      end

      if @target_index_key && @target_index_key.is_a?(String)
        @target_index_key = @target_index_key.split '.'
      end

      if @remove_keys_on_update && @remove_keys_on_update.is_a?(String)
        @remove_keys_on_update = @remove_keys_on_update.split ','
      end

      raise Fluent::ConfigError, "'max_retry_putting_template' must be greater than or equal to zero." if @max_retry_putting_template < 0
      raise Fluent::ConfigError, "'max_retry_get_os_version' must be greater than or equal to zero." if @max_retry_get_os_version < 0

      # Dump log when using host placeholders and template features at same time.
      valid_host_placeholder = placeholder?(:host_placeholder, @host)
      if valid_host_placeholder && (@template_name && @template_file || @templates)
        if @verify_os_version_at_startup
          raise Fluent::ConfigError, "host placeholder, template installation, and verify OpenSearch version at startup are exclusive feature at same time. Please specify verify_os_version_at_startup as `false` when host placeholder and template installation are enabled."
        end
        log.info "host placeholder and template installation makes your OpenSearch cluster a bit slow down(beta)."
      end

      @template_names = []
      if !dry_run?
        if @template_name && @template_file
          if @logstash_format || placeholder_substitution_needed_for_template?
            class << self
              alias_method :template_installation, :template_installation_actual
            end
          else
            template_installation_actual(@template_name, @customize_template, @application_name, @index_name)
          end
        end
        if @templates
          retry_operate(@max_retry_putting_template,
                        @fail_on_putting_template_retry_exceed,
                        @catch_transport_exception_on_retry) do
            templates_hash_install(@templates, @template_overwrite)
          end
        end
      end

      @truncate_mutex = Mutex.new
      if @truncate_caches_interval
        timer_execute(:out_opensearch_truncate_caches, @truncate_caches_interval) do
          log.info('Clean up the indices and template names cache')

          @truncate_mutex.synchronize {
            @template_names.clear
          }
        end
      end
      # If AWS credentials is set, consider to expire credentials information forcibly before expired.
      @credential_mutex = Mutex.new
      if @endpoint
        @_aws_credentials = aws_credentials(@endpoint)

        if @endpoint.refresh_credentials_interval
          @duration_seconds = Fluent::Config.time_value(@endpoint.refresh_credentials_interval)
          # 60 * 60 * 12 = 12 hours
          if @duration_seconds > 43200
            raise Fluent::ConfigError, "Maximum duration is 12 hours."
          end

          # 60 * 15 = 15 minutes
          if @duration_seconds < 900
            raise Fluent::ConfigError, "Minimum duration is 15 minutes."
          end

          timer_execute(:out_opensearch_expire_credentials, @duration_seconds) do
            log.debug('Recreate the AWS credentials')

            @credential_mutex.synchronize do
              @_os = nil
              @_aws_credentials = aws_credentials(@endpoint)
            end
          end
        end
      end

      @serializer_class = nil
      begin
        require 'oj'
        @dump_proc = Oj.method(:dump)
        if @prefer_oj_serializer
          @serializer_class = Fluent::Plugin::Serializer::Oj
          OpenSearch::API.settings[:serializer] = Fluent::Plugin::Serializer::Oj
        end
      rescue LoadError
        @dump_proc = Yajl.method(:dump)
      end

      raise Fluent::ConfigError, "`password` must be present if `user` is present" if @user && @password.nil?

      if @user && m = @user.match(/%{(?<user>.*)}/)
        @user = URI.encode_www_form_component(m["user"])
      end
      if @password && m = @password.match(/%{(?<password>.*)}/)
        @password = URI.encode_www_form_component(m["password"])
      end

      @transport_logger = nil
      if @with_transporter_log
        @transport_logger = log
        log_level = conf['@log_level'] || conf['log_level']
        log.warn "Consider to specify log_level with @log_level." unless log_level
      end
      # Specify @sniffer_class before calling #client.
      # #detect_os_major_version uses #client.
      @sniffer_class = nil
      begin
        @sniffer_class = Object.const_get(@sniffer_class_name) if @sniffer_class_name
      rescue Exception => ex
        raise Fluent::ConfigError, "Could not load sniffer class #{@sniffer_class_name}: #{ex}"
      end

      @selector_class = nil
      begin
        @selector_class = Object.const_get(@selector_class_name) if @selector_class_name
      rescue Exception => ex
        raise Fluent::ConfigError, "Could not load selector class #{@selector_class_name}: #{ex}"
      end

      @last_seen_major_version = if major_version = handle_last_seen_os_major_version
                                   major_version
                                 else
                                   @default_opensearch_version
                                 end

      if @validate_client_version && !dry_run?
        if @last_seen_major_version != client_library_version.to_i
          raise Fluent::ConfigError, <<-EOC
            Detected OpenSearch #{@last_seen_major_version} but you use OpenSearch client #{client_library_version}.
            Please consider to use #{@last_seen_major_version}.x series OpenSearch client.
          EOC
        end
      end

      if @last_seen_major_version >= 1
        case @ssl_version
        when :SSLv23, :TLSv1, :TLSv1_1
          if @scheme == :https
            log.warn "Detected OpenSearch 1.x or above and enabled insecure security:
                      You might have to specify `ssl_version TLSv1_2` in configuration."
          end
        end
      end

      if @ssl_version && @scheme == :https
        if !@http_backend_excon_nonblock
          log.warn "TLS handshake will be stucked with block connection.
                    Consider to set `http_backend_excon_nonblock` as true"
        end
      end

      # Consider missing the prefix of "$." in nested key specifiers.
      @id_key = convert_compat_id_key(@id_key) if @id_key
      @parent_key = convert_compat_id_key(@parent_key) if @parent_key
      @routing_key = convert_compat_id_key(@routing_key) if @routing_key

      @routing_key_name = configure_routing_key_name
      @meta_config_map = create_meta_config_map
      @current_config = nil
      @compressable_connection = false

      @ignore_exception_classes = @ignore_exceptions.map do |exception|
        unless Object.const_defined?(exception)
          log.warn "Cannot find class #{exception}. Will ignore it."

          nil
        else
          Object.const_get(exception)
        end
      end.compact

      if @bulk_message_request_threshold < 0
        class << self
          alias_method :split_request?, :split_request_size_uncheck?
        end
      else
        class << self
          alias_method :split_request?, :split_request_size_check?
        end
      end
    end

    def dry_run?
      if Fluent::Engine.respond_to?(:dry_run_mode)
        Fluent::Engine.dry_run_mode
      elsif Fluent::Engine.respond_to?(:supervisor_mode)
        Fluent::Engine.supervisor_mode
      end
    end

    def placeholder?(name, param)
      placeholder_validities = []
      placeholder_validators(name, param).each do |v|
        begin
          v.validate!
          placeholder_validities << true
        rescue Fluent::ConfigError => e
          log.debug("'#{name} #{param}' is tested built-in placeholder(s) but there is no valid placeholder(s). error: #{e}")
          placeholder_validities << false
        end
      end
      placeholder_validities.include?(true)
    end

    def emit_error_label_event?
      !!@emit_error_label_event
    end

    def compression
      !(@compression_level == :no_compression)
    end

    def compression_strategy
      case @compression_level
      when :default_compression
        Zlib::DEFAULT_COMPRESSION
      when :best_compression
        Zlib::BEST_COMPRESSION
      when :best_speed
        Zlib::BEST_SPEED
      else
        Zlib::NO_COMPRESSION
      end
    end

    def backend_options
      case @http_backend
      when :excon
        { client_key: @client_key, client_cert: @client_cert, client_key_pass: @client_key_pass, nonblock: @http_backend_excon_nonblock }
      when :typhoeus
        require 'faraday/typhoeus'
        { sslkey: @client_key, sslcert: @client_cert, keypasswd: @client_key_pass }
      end
    rescue LoadError => ex
      log.error_backtrace(ex.backtrace)
      raise Fluent::ConfigError, "You must install #{@http_backend} gem. Exception: #{ex}"
    end

    def handle_last_seen_os_major_version
      if @verify_os_version_at_startup && !dry_run?
        retry_operate(@max_retry_get_os_version,
                      @fail_on_detecting_os_version_retry_exceed,
                      @catch_transport_exception_on_retry) do
          detect_os_major_version
        end
      else
        nil
      end
    end

    def detect_os_major_version
      @_os_info ||= client.info
      begin
        unless version = @_os_info.dig("version", "number")
          version = @default_opensearch_version
        end
      rescue NoMethodError => e
        log.warn "#{@_os_info} can not dig version information. Assuming OpenSearch #{@default_opensearch_version}", error: e
        version = @default_opensearch_version
      end
      version.to_i
    end

    def client_library_version
      OpenSearch::VERSION
    end

    def configure_routing_key_name
      'routing'.freeze
    end

    def convert_compat_id_key(key)
      if key.include?('.') && !key.start_with?('$[')
        key = "$.#{key}" unless key.start_with?('$.')
      end
      key
    end

    def create_meta_config_map
      result = []
      result << [record_accessor_create(@id_key), '_id'] if @id_key
      result << [record_accessor_create(@parent_key), '_parent'] if @parent_key
      result << [record_accessor_create(@routing_key), @routing_key_name] if @routing_key
      result
    end

    # once fluent v0.14 is released we might be able to use
    # Fluent::Parser::TimeParser, but it doesn't quite do what we want - if gives
    # [sec,nsec] where as we want something we can call `strftime` on...
    def create_time_parser
      if @time_key_format
        begin
          # Strptime doesn't support all formats, but for those it does it's
          # blazingly fast.
          strptime = Strptime.new(@time_key_format)
          Proc.new { |value|
            value = convert_numeric_time_into_string(value, @time_key_format) if value.is_a?(Numeric)
            strptime.exec(value).to_datetime
          }
        rescue
          # Can happen if Strptime doesn't recognize the format; or
          # if strptime couldn't be required (because it's not installed -- it's
          # ruby 2 only)
          Proc.new { |value|
            value = convert_numeric_time_into_string(value, @time_key_format) if value.is_a?(Numeric)
            DateTime.strptime(value, @time_key_format)
          }
        end
      else
        Proc.new { |value|
          value = convert_numeric_time_into_string(value) if value.is_a?(Numeric)
          DateTime.parse(value)
        }
      end
    end

    def convert_numeric_time_into_string(numeric_time, time_key_format = "%Y-%m-%d %H:%M:%S.%N%z")
      numeric_time_parser = Fluent::NumericTimeParser.new(:float)
      Time.at(numeric_time_parser.parse(numeric_time).to_r).strftime(time_key_format)
    end

    def parse_time(value, event_time, tag)
      @time_parser.call(value)
    rescue => e
      if emit_error_label_event?
        router.emit_error_event(@time_parse_error_tag, Fluent::Engine.now, {'tag' => tag, 'time' => event_time, 'format' => @time_key_format, 'value' => value}, e)
      end
      return Time.at(event_time).to_datetime
    end

    def client(host = nil, compress_connection = false)
      # check here to see if we already have a client connection for the given host
      connection_options = get_connection_options(host)

      @_os = nil unless is_existing_connection(connection_options[:hosts])
      @_os = nil unless @compressable_connection == compress_connection

      @_os ||= begin
        @compressable_connection = compress_connection
        @current_config = connection_options[:hosts].clone
        adapter_conf = if @endpoint
                         lambda do |f|
                           f.request(
                             :aws_sigv4,
                             service: @endpoint.aws_service_name.to_s,
                             region: @endpoint.region,
                             credentials: @_aws_credentials,
                           )

                           f.adapter @http_backend, @backend_options
                         end
                       else
                         lambda {|f| f.adapter @http_backend, @backend_options }
                       end

        local_reload_connections = @reload_connections
        if local_reload_connections && @reload_after > DEFAULT_RELOAD_AFTER
          local_reload_connections = @reload_after
        end

        gzip_headers = if compress_connection
                         {'Content-Encoding' => 'gzip'}
                       else
                         {}
                       end
        headers = {}.merge(@custom_headers)
                    .merge(gzip_headers)
        ssl_options = { verify: @ssl_verify, ca_file: @ca_file}.merge(@ssl_version_options)

        transport = OpenSearch::Transport::Transport::HTTP::Faraday.new(connection_options.merge(
                                                                            options: {
                                                                              reload_connections: local_reload_connections,
                                                                              reload_on_failure: @reload_on_failure,
                                                                              resurrect_after: @resurrect_after,
                                                                              logger: @transport_logger,
                                                                              transport_options: {
                                                                                headers: headers,
                                                                                request: { timeout: @request_timeout },
                                                                                ssl: ssl_options,
                                                                              },
                                                                              http: {
                                                                                user: @user,
                                                                                password: @password,
                                                                                scheme: @scheme
                                                                              },
                                                                              sniffer_class: @sniffer_class,
                                                                              serializer_class: @serializer_class,
                                                                              selector_class: @selector_class,
                                                                              compression: compress_connection,
                                                                            }), &adapter_conf)
        OpenSearch::Client.new transport: transport
      end
    end

    def get_escaped_userinfo(host_str)
      if m = host_str.match(/(?<scheme>.*)%{(?<user>.*)}:%{(?<password>.*)}(?<path>@.*)/)
        m["scheme"] +
          URI.encode_www_form_component(m["user"]) +
          ':' +
          URI.encode_www_form_component(m["password"]) +
          m["path"]
      else
        host_str
      end
    end

    def get_connection_options(con_host=nil)

      hosts = if @endpoint # For AWS OpenSearch Service
        uri = URI(@endpoint.url)
        host = %w(user password path).inject(host: uri.host, port: uri.port, scheme: uri.scheme) do |hash, key|
          hash[key.to_sym] = uri.public_send(key) unless uri.public_send(key).nil? || uri.public_send(key) == ''
          hash
        end
        [host]
      elsif con_host || @hosts
        (con_host || @hosts).split(',').map do |host_str|
          # Support legacy hosts format host:port,host:port,host:port...
          if host_str.match(%r{^[^:]+(\:\d+)?$})
            {
              host:   host_str.split(':')[0],
              port:   (host_str.split(':')[1] || @port).to_i,
              scheme: @scheme.to_s
            }
          else
            # New hosts format expects URLs such as http://logs.foo.com,https://john:pass@logs2.foo.com/elastic
            uri = URI(get_escaped_userinfo(host_str))
            %w(user password path).inject(host: uri.host, port: uri.port, scheme: uri.scheme) do |hash, key|
              hash[key.to_sym] = uri.public_send(key) unless uri.public_send(key).nil? || uri.public_send(key) == ''
              hash
            end
          end
        end.compact
      else
        if Resolv::IPv6::Regex.match(@host)
          [{host: "[#{@host}]", scheme: @scheme.to_s, port: @port}]
        else
          [{host: @host, port: @port, scheme: @scheme.to_s}]
        end
      end.each do |host|
        host.merge!(user: @user, password: @password) if !host[:user] && @user
        host.merge!(path: @path) if !host[:path] && @path
      end

      {
        hosts: hosts
      }
    end

    def connection_options_description(con_host=nil)
      get_connection_options(con_host)[:hosts].map do |host_info|
        attributes = host_info.dup
        attributes[:password] = 'obfuscated' if attributes.has_key?(:password)
        attributes.inspect
      end.join(', ')
    end

    # append_record_to_messages adds a record to the bulk message
    # payload to be submitted to OpenSearch.  Records that do
    # not include '_id' field are skipped when 'write_operation'
    # is configured for 'create' or 'update'
    #
    # returns 'true' if record was appended to the bulk message
    #         and 'false' otherwise
    def append_record_to_messages(op, meta, header, record, msgs)
      case op
      when UPDATE_OP, UPSERT_OP
        if meta.has_key?(ID_FIELD)
          header[UPDATE_OP] = meta
          msgs << @dump_proc.call(header) << BODY_DELIMITER
          msgs << @dump_proc.call(update_body(record, op)) << BODY_DELIMITER
          return true
        end
      when CREATE_OP
        if meta.has_key?(ID_FIELD)
          header[CREATE_OP] = meta
          msgs << @dump_proc.call(header) << BODY_DELIMITER
          msgs << @dump_proc.call(record) << BODY_DELIMITER
          return true
        end
      when INDEX_OP
        header[INDEX_OP] = meta
        msgs << @dump_proc.call(header) << BODY_DELIMITER
        msgs << @dump_proc.call(record) << BODY_DELIMITER
        return true
      end
      return false
    end

    def update_body(record, op)
      update = remove_keys(record)
      if @suppress_doc_wrap
        return update
      end
      body = {"doc".freeze => update}
      if op == UPSERT_OP
        if update == record
          body["doc_as_upsert".freeze] = true
        else
          body[UPSERT_OP] = record
        end
      end
      body
    end

    def remove_keys(record)
      keys = record[@remove_keys_on_update_key] || @remove_keys_on_update || []
      record.delete(@remove_keys_on_update_key)
      return record unless keys.any?
      record = record.dup
      keys.each { |key| record.delete(key) }
      record
    end

    def flatten_record(record, prefix=[])
      ret = {}
      if record.is_a? Hash
        record.each { |key, value|
          ret.merge! flatten_record(value, prefix + [key.to_s])
        }
      elsif record.is_a? Array
        # Don't mess with arrays, leave them unprocessed
        ret.merge!({prefix.join(@flatten_hashes_separator) => record})
      else
        return {prefix.join(@flatten_hashes_separator) => record}
      end
      ret
    end

    def expand_placeholders(chunk)
      logstash_prefix = extract_placeholders(@logstash_prefix, chunk)
      logstash_dateformat = extract_placeholders(@logstash_dateformat, chunk)
      index_name = extract_placeholders(@index_name, chunk)
      if @template_name
        template_name = extract_placeholders(@template_name, chunk)
      else
        template_name = nil
      end
      if @customize_template
        customize_template = @customize_template.each_with_object({}) { |(key, value), hash| hash[key] = extract_placeholders(value, chunk) }
      else
        customize_template = nil
      end
      if @application_name
        application_name = extract_placeholders(@application_name, chunk)
      else
        application_name = nil
      end
      if @pipeline
        pipeline = extract_placeholders(@pipeline, chunk)
      else
        pipeline = nil
      end
      return logstash_prefix, logstash_dateformat, index_name, template_name, customize_template, application_name, pipeline
    end

    def multi_workers_ready?
      true
    end

    def inject_chunk_id_to_record_if_needed(record, chunk_id)
      if @metainfo&.include_chunk_id
        record[@metainfo.chunk_id_key] = chunk_id
        record
      else
        record
      end
    end

    def write(chunk)
      bulk_message_count = Hash.new { |h,k| h[k] = 0 }
      bulk_message = Hash.new { |h,k| h[k] = '' }
      header = {}
      meta = {}

      tag = chunk.metadata.tag
      chunk_id = dump_unique_id_hex(chunk.unique_id)
      extracted_values = expand_placeholders(chunk)
      host = if @hosts
               extract_placeholders(@hosts, chunk)
             else
               extract_placeholders(@host, chunk)
             end

      affinity_target_indices = get_affinity_target_indices(chunk)
      chunk.msgpack_each do |time, record|
        next unless record.is_a? Hash

        record = inject_chunk_id_to_record_if_needed(record, chunk_id)

        begin
          meta, header, record = process_message(tag, meta, header, time, record, affinity_target_indices, extracted_values)
          info = if @include_index_in_url
                   RequestInfo.new(host, meta.delete("_index".freeze), meta["_index".freeze], meta.delete("_alias".freeze))
                 else
                   RequestInfo.new(host, nil, meta["_index".freeze], meta.delete("_alias".freeze))
                 end

          if split_request?(bulk_message, info)
            bulk_message.each do |info, msgs|
              send_bulk(msgs, tag, chunk, bulk_message_count[info], extracted_values, info) unless msgs.empty?
              msgs.clear
              # Clear bulk_message_count for this info.
              bulk_message_count[info] = 0;
              next
            end
          end

          if append_record_to_messages(@write_operation, meta, header, record, bulk_message[info])
            bulk_message_count[info] += 1;
          else
            if @emit_error_for_missing_id
              raise MissingIdFieldError, "Missing '_id' field. Write operation is #{@write_operation}"
            else
              log.on_debug { log.debug("Dropping record because its missing an '_id' field and write_operation is #{@write_operation}: #{record}") }
            end
          end
        rescue => e
          if emit_error_label_event?
            router.emit_error_event(tag, time, record, e)
          end
        end
      end

      bulk_message.each do |info, msgs|
        send_bulk(msgs, tag, chunk, bulk_message_count[info], extracted_values, info) unless msgs.empty?
        msgs.clear
      end
    end

    def target_index_affinity_enabled?()
      @target_index_affinity && @logstash_format && @id_key && (@write_operation == UPDATE_OP || @write_operation == UPSERT_OP)
    end

    def get_affinity_target_indices(chunk)
      indices = Hash.new
      if target_index_affinity_enabled?()
        id_key_accessor = record_accessor_create(@id_key)
        ids = Set.new
        chunk.msgpack_each do |time, record|
          next unless record.is_a? Hash
          begin
            ids << id_key_accessor.call(record)
          end
        end
        log.debug("Find affinity target_indices by quering on OpenSearch (write_operation #{@write_operation}) for ids: #{ids.to_a}")
        options = {
          :index => "#{logstash_prefix}#{@logstash_prefix_separator}*",
        }
        query = {
          'query' => { 'ids' => { 'values' => ids.to_a } },
          '_source' => false,
          'sort' => [
            {"_index" => {"order" => "desc"}}
         ]
        }
        result = client.search(options.merge(:body => Yajl.dump(query)))
        # There should be just one hit per _id, but in case there still is multiple, just the oldest index is stored to map
        result['hits']['hits'].each do |hit|
          indices[hit["_id"]] = hit["_index"]
          log.debug("target_index for id: #{hit["_id"]} from es: #{hit["_index"]}")
        end
      end
      indices
    end

    def split_request?(bulk_message, info)
      # For safety.
    end

    def split_request_size_check?(bulk_message, info)
      bulk_message[info].size > @bulk_message_request_threshold
    end

    def split_request_size_uncheck?(bulk_message, info)
      false
    end

    def process_message(tag, meta, header, time, record, affinity_target_indices, extracted_values)
      logstash_prefix, logstash_dateformat, index_name, _template_name, _customize_template, application_name, pipeline = extracted_values

      if @flatten_hashes
        record = flatten_record(record)
      end

      dt = nil
      if @logstash_format || @include_timestamp
        if record.has_key?(TIMESTAMP_FIELD)
          rts = record[TIMESTAMP_FIELD]
          dt = parse_time(rts, time, tag)
        elsif record.has_key?(@time_key)
          rts = record[@time_key]
          dt = parse_time(rts, time, tag)
          record[TIMESTAMP_FIELD] = dt.iso8601(@time_precision) unless @time_key_exclude_timestamp
        else
          dt = Time.at(time).to_datetime
          record[TIMESTAMP_FIELD] = dt.iso8601(@time_precision)
        end
      end

      target_index_parent, target_index_child_key = @target_index_key ? get_parent_of(record, @target_index_key) : nil
      if target_index_parent && target_index_parent[target_index_child_key]
        target_index_alias = target_index = target_index_parent.delete(target_index_child_key)
      elsif @logstash_format
        dt = dt.new_offset(0) if @utc_index
        target_index = "#{logstash_prefix}#{@logstash_prefix_separator}#{dt.strftime(logstash_dateformat)}"
        target_index_alias = "#{logstash_prefix}#{@logstash_prefix_separator}#{application_name}#{@logstash_prefix_separator}#{dt.strftime(logstash_dateformat)}"
      else
        target_index_alias = target_index = index_name
      end

      # Change target_index to lower-case since OpenSearch doesn't
      # allow upper-case characters in index names.
      target_index = target_index.downcase
      target_index_alias = target_index_alias.downcase
      if @include_tag_key
        record[@tag_key] = tag
      end

      # If affinity target indices map has value for this particular id, use it as target_index
      if !affinity_target_indices.empty?
        id_accessor = record_accessor_create(@id_key)
        id_value = id_accessor.call(record)
        if affinity_target_indices.key?(id_value)
          target_index = affinity_target_indices[id_value]
        end
      end

      if @suppress_type_name || @last_seen_major_version >= 2
        target_type = nil
      else
        # OpenSearch only supports "_doc".
        target_type = DEFAULT_TYPE_NAME
      end

      meta.clear
      meta["_index".freeze] = target_index
      meta["_type".freeze] = target_type unless target_type.nil?
      meta["_alias".freeze] = target_index_alias

      if @pipeline
        meta["pipeline".freeze] = pipeline
      end

      @meta_config_map.each do |record_accessor, meta_key|
        if raw_value = record_accessor.call(record)
          meta[meta_key] = raw_value
        end
      end

      if @remove_keys
        @remove_keys.each { |key| record.delete(key) }
      end

      return [meta, header, record]
    end

    # returns [parent, child_key] of child described by path array in record's tree
    # returns [nil, child_key] if path doesnt exist in record
    def get_parent_of(record, path)
      parent_object = path[0..-2].reduce(record) { |a, e| a.is_a?(Hash) ? a[e] : nil }
      [parent_object, path[-1]]
    end

    # gzip compress data
    def gzip(string)
      wio = StringIO.new("w")
      w_gz = Zlib::GzipWriter.new(wio, strategy = compression_strategy)
      w_gz.write(string)
      w_gz.close
      wio.string
    end

    def placeholder_substitution_needed_for_template?
      need_substitution = placeholder?(:host, @host.to_s) ||
        placeholder?(:index_name, @index_name.to_s) ||
        placeholder?(:template_name, @template_name.to_s) ||
        @customize_template&.values&.any? { |value| placeholder?(:customize_template, value.to_s) } ||
        placeholder?(:logstash_prefix, @logstash_prefix.to_s) ||
        placeholder?(:logstash_dateformat, @logstash_dateformat.to_s) ||
        placeholder?(:application_name, @application_name.to_s) ||
      log.debug("Need substitution: #{need_substitution}")
      need_substitution
    end

    def template_installation(template_name, customize_template, application_name, target_index, host)
      # for safety.
    end

    def template_installation_actual(template_name, customize_template, application_name, target_index, host=nil)
      if template_name && @template_file
        if !@logstash_format && @template_names.include?(template_name)
          log.debug("Template #{template_name} already exists (cached)")
        else
          retry_operate(@max_retry_putting_template,
                        @fail_on_putting_template_retry_exceed,
                        @catch_transport_exception_on_retry) do
            if customize_template
              template_custom_install(template_name, @template_file, @template_overwrite, customize_template, host, target_index, @index_separator)
            else
              template_install(template_name, @template_file, @template_overwrite, host, target_index, @index_separator)
            end
          end
          @template_names << template_name
        end
      end
    end

    # send_bulk given a specific bulk request, the original tag,
    # chunk, and bulk_message_count
    def send_bulk(data, tag, chunk, bulk_message_count, extracted_values, info)
      _logstash_prefix, _logstash_dateformat, index_name, template_name, customize_template, application_name, _pipeline  = extracted_values
      template_installation(template_name, customize_template, application_name, index_name, info.host)

      begin

        log.on_trace { log.trace "bulk request: #{data}" }

        prepared_data = if compression
                          gzip(data)
                        else
                          data
                        end

        response = client(info.host, compression).bulk body: prepared_data, index: info.index
        log.on_trace { log.trace "bulk response: #{response}" }

        if response['errors']
          error = Fluent::Plugin::OpenSearchErrorHandler.new(self)
          error.handle_error(response, tag, chunk, bulk_message_count, extracted_values)
        end
      rescue RetryStreamError => e
        log.trace "router.emit_stream for retry stream doing..."
        emit_tag = @retry_tag ? @retry_tag : tag
        # check capacity of buffer space
        if retry_stream_retryable?
          router.emit_stream(emit_tag, e.retry_stream)
        else
          raise RetryStreamEmitFailure, "buffer is full."
        end
        log.trace "router.emit_stream for retry stream done."
      rescue => e
        ignore = @ignore_exception_classes.any? { |clazz| e.class <= clazz }

        log.warn "Exception ignored in tag #{tag}: #{e.class.name} #{e.message}" if ignore

        @_os = nil if @reconnect_on_error
        @_os_info = nil if @reconnect_on_error

        raise UnrecoverableRequestFailure if ignore && @exception_backup

        # FIXME: identify unrecoverable errors and raise UnrecoverableRequestFailure instead
        raise RecoverableRequestFailure, "could not push logs to OpenSearch cluster (#{connection_options_description(info.host)}): #{e.message}" unless ignore
      end
    end

    def retry_stream_retryable?
      @buffer.storable?
    end

    def is_existing_connection(host)
      # check if the host provided match the current connection
      return false if @_os.nil?
      return false if @current_config.nil?
      return false if host.length != @current_config.length

      for i in 0...host.length
        if !host[i][:host].eql? @current_config[i][:host] || host[i][:port] != @current_config[i][:port]
          return false
        end
      end

      return true
    end
  end
end
