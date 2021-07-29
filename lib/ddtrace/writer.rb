require 'json'

require 'ddtrace/ext/net'
require 'datadog/core/environment/socket'

require 'ddtrace/configuration/agent_settings_resolver'
require 'ddtrace/transport/http'
require 'ddtrace/transport/io'
require 'ddtrace/encoding'
require 'ddtrace/workers'
require 'ddtrace/diagnostics/environment_logger'
require 'ddtrace/utils/only_once'

module Datadog
  # Processor that sends traces and metadata to the agent
  class Writer
    DEPRECATION_WARN_ONLY_ONCE = Datadog::Utils::OnlyOnce.new

    attr_reader \
      :priority_sampler,
      :transport,
      :worker

    def initialize(options = {})
      # writer and transport parameters
      @buff_size = options.fetch(:buffer_size, Workers::AsyncTransport::DEFAULT_BUFFER_MAX_SIZE)
      @flush_interval = options.fetch(:flush_interval, Workers::AsyncTransport::DEFAULT_FLUSH_INTERVAL)
      transport_options = options.fetch(:transport_options, {})

      transport_options[:agent_settings] = options[:agent_settings] if options.key?(:agent_settings)

      # priority sampling
      if options[:priority_sampler]
        @priority_sampler = options[:priority_sampler]
        transport_options[:api_version] ||= Transport::HTTP::API::V4
      end

      # transport and buffers
      @transport = options.fetch(:transport) do
        Transport::HTTP.default(**transport_options)
      end

      # handles the thread creation after an eventual fork
      @mutex_after_fork = Mutex.new
      @pid = nil

      @traces_flushed = 0

      # one worker for traces
      @worker = nil

      # Once stopped, this writer instance cannot be restarted.
      # This allow for graceful shutdown, while preventing
      # the host application from inadvertently start new
      # threads during shutdown.
      @stopped = false
    end

    def start
      @mutex_after_fork.synchronize do
        return false if @stopped

        pid = Process.pid
        return if @worker && pid == @pid

        @pid = pid

        start_worker
        true
      end
    end

    # spawns a worker for spans; they share the same transport which is thread-safe
    def start_worker
      @trace_handler = ->(items, transport) { send_spans(items, transport) }
      @worker = Datadog::Workers::AsyncTransport.new(
        transport: @transport,
        buffer_size: @buff_size,
        on_trace: @trace_handler,
        interval: @flush_interval
      )

      @worker.start
    end

    # Gracefully shuts down this writer.
    #
    # Once stopped methods calls won't fail, but
    # no internal work will be performed.
    #
    # It is not possible to restart a stopped writer instance.
    def stop
      @mutex_after_fork.synchronize { stop_worker }
    end

    def stop_worker
      @stopped = true

      return if @worker.nil?

      @worker.stop
      @worker = nil

      true
    end

    private :start_worker, :stop_worker

    # flush spans to the trace-agent, handles spans only
    def send_spans(traces, transport)
      return true if traces.empty?

      # Inject hostname if configured to do so
      inject_hostname!(traces) if Datadog.configuration.report_hostname

      # Send traces and get responses
      responses = transport.send_traces(traces)

      # Tally up successful flushes
      responses.reject { |x| x.internal_error? || x.server_error? }.each do |response|
        @traces_flushed += response.trace_count
      end

      # Update priority sampler
      update_priority_sampler(responses.last)

      record_environment_information!(responses)

      # Return if server error occurred.
      !responses.find(&:server_error?)
    end

    # enqueue the trace for submission to the API
    def write(trace, services = nil)
      unless services.nil?
        DEPRECATION_WARN_ONLY_ONCE.run do
          Datadog.logger.warn(%(
            write: Writing services has been deprecated and no longer need to be provided.
            write(traces, services) can be updated to write(traces)
          ))
        end
      end

      # In multiprocess environments, the main process initializes the +Writer+ instance and if
      # the process forks (i.e. a web server like Unicorn or Puma with multiple workers) the new
      # processes will share the same +Writer+ until the first write (COW). Because of that,
      # each process owns a different copy of the +@buffer+ after each write and so the
      # +AsyncTransport+ will not send data to the trace agent.
      #
      # This check ensures that if a process doesn't own the current +Writer+, async workers
      # will be initialized again (but only once for each process).
      start if @worker.nil? || @pid != Process.pid

      # TODO: Remove this, and have the tracer pump traces directly to runtime metrics
      #       instead of working through the trace writer.
      # Associate root span with runtime metrics
      if Datadog.configuration.runtime_metrics.enabled && !trace.empty?
        Datadog.runtime_metrics.associate_with_span(trace.first)
      end

      worker_local = @worker

      if worker_local
        worker_local.enqueue_trace(trace)
      elsif !@stopped
        Datadog.logger.debug('Writer either failed to start or was stopped before #write could complete')
      end
    end

    # stats returns a dictionary of stats about the writer.
    def stats
      {
        traces_flushed: @traces_flushed,
        transport: @transport.stats
      }
    end

    private

    def inject_hostname!(traces)
      traces.each do |trace|
        next if trace.first.nil?

        hostname = Datadog::Core::Environment::Socket.hostname
        trace.first.set_tag(Ext::NET::TAG_HOSTNAME, hostname) unless hostname.nil? || hostname.empty?
      end
    end

    def update_priority_sampler(response)
      return unless response && !response.internal_error? && priority_sampler && response.service_rates

      priority_sampler.update(response.service_rates)
    end

    def record_environment_information!(responses)
      Diagnostics::EnvironmentLogger.log!(responses)
    end
  end
end
