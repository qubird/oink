require 'hodel_3000_compliant_logger'
require 'oink/utils/hash_utils'
require 'oink/instrumentation'
require 'socket'

module Oink
  class Middleware

    def initialize(app, options = {})
      @app         = app
      @logger      = options[:logger] || Hodel3000CompliantLogger.new("log/oink.log")
      @instruments = options[:instruments] ? Array(options[:instruments]) : [:memory, :activerecord]
      if ENV['RAILS_ENV'] == 'production'
        @cube = options[:cube] || nil
      else
        @cube = nil
      end
      @sock  = UDPSocket.new

      ActiveRecord::Base.send(:include, Oink::Instrumentation::ActiveRecord) if @instruments.include?(:activerecord)
    end

    def call(env)
      status, headers, body = @app.call(env)
      log_routing(env)
      log_memory()
      log_activerecord()
      log_completed
      [status, headers, body]
    end

    def log_completed
      @logger.info("Oink Log Entry Complete")
    end

    def log_routing(env)
      routing_info = rails3_routing_info(env) || rails2_routing_info(env)
      if routing_info
        controller = routing_info['controller']
        action     = routing_info['action']
        @logger.info("Oink Action: #{controller}##{action}")
      end
    end

    def log_memory
      if @instruments.include?(:memory)
        memory = Oink::Instrumentation::MemorySnapshot.memory
        @logger.info("Memory usage: #{memory} | PID: #{$$}")
        if @cube != nil
          message = JSON.dump(
          {
            :type => 'kraken-rails-memory',
            :time => Time.now,
            :data => {
              :memory => memory
            }
          })
          @sock.send message, 0, @cube[:address], @cube[:port]
        end
      end
    end

    def log_activerecord
      if @instruments.include?(:activerecord)
        sorted_list = Oink::HashUtils.to_sorted_array(ActiveRecord::Base.instantiated_hash)
        sorted_list.unshift("Total: #{ActiveRecord::Base.total_objects_instantiated}")
        @logger.info("Instantiation Breakdown: #{sorted_list.join(' | ')}")
        reset_objects_instantiated
      end
    end

  private

    def rails3_routing_info(env)
      env['action_dispatch.request.parameters']
    end

    def rails2_routing_info(env)
      env['action_controller.request.path_parameters']
    end

    def reset_objects_instantiated
      ActiveRecord::Base.reset_instance_type_count
    end

  end
end
