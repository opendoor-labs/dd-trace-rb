module Datadog
  module Contrib
    module Rails
      # TODO[manu]: write docs
      module ActionControllerSubscriber
        def self.start_processing(*)
          tracer = ::Rails.configuration.datadog_trace.fetch(:tracer)
          tracer.trace('rails.request', service: 'rails-app', type: 'web')
        rescue StandardError => e
          # TODO[manu]: better error handling
          puts e
        end

        def self.process_action(_name, start, finish, _id, payload)
          tracer = ::Rails.configuration.datadog_trace.fetch(:tracer)
          span = tracer.buffer.get
          span.resource = "#{payload.fetch(:controller)}##{payload.fetch(:action)}"
          span.set_tag('http.url', payload.fetch(:path))
          span.set_tag('http.method', payload.fetch(:method))
          span.set_tag('http.status_code', payload.fetch(:status).to_s)
          span.set_tag('rails.route.action', payload.fetch(:action))
          span.set_tag('rails.route.controller', payload.fetch(:controller))
          span.start_time = start
          span.finish_at(finish)
        rescue StandardError => e
          # TODO[manu]: better error handling
          puts e
        end
      end
    end
  end
end
