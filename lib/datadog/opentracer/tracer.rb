# typed: false

require 'time'

require_relative '../tracing/context'
require_relative '../tracing/tracer'

module Datadog
  module OpenTracer
    # OpenTracing adapter for Datadog::Tracer
    # @public_api
    class Tracer < ::OpenTracing::Tracer
      # (see Datadog::Tracer)
      # @return [Datadog::Tracer]
      attr_reader \
        :datadog_tracer

      # (see Datadog::Tracer#initialize)
      def initialize(**options)
        super()
        @datadog_tracer = Datadog::Tracing::Tracer.new(**options)
      end

      # @return [ScopeManager] the current ScopeManager.
      def scope_manager
        @scope_manager ||= ThreadLocalScopeManager.new
      end

      # Returns a newly started and activated {Scope}.
      #
      # If `scope_manager.active` is not nil, no explicit references
      # are provided, and `ignore_active_scope` is false, then an inferred
      # {https://www.rubydoc.info/gems/opentracing/0.5.0/OpenTracing/Reference OpenTracing::Reference#CHILD_OF}
      # reference is created to the `scope_manager.active`'s
      # {SpanContext} when {#start_active_span} is invoked.
      #
      # @param operation_name [String] The operation name for the Span
      # @param child_of [SpanContext, Span] SpanContext that acts as a parent to
      #   the newly-started Span. If a Span instance is provided, its
      #   context is automatically substituted. See [OpenTracing::Reference] for more
      #   information.
      #   If specified, the `references` parameter must be omitted.
      # @param references [Array<OpenTracing::Reference>] An array of reference
      #   objects that identify one or more parent SpanContexts.
      # @param start_time [Time] When the Span started, if not now
      # @param tags [Hash] Tags to assign to the Span at start time
      # @param ignore_active_scope [Boolean] whether to create an implicit
      #   OpenTracing::Reference#CHILD_OF reference to the ScopeManager#active.
      # @param finish_on_close [Boolean] whether span should automatically be
      #   finished when Scope#close is called
      # @yield [Scope] If an optional block is passed to start_active it will
      #   yield the newly-started Scope. If `finish_on_close` is true then the
      #   Span will be finished automatically after the block is executed.
      # @return [Scope] The newly-started and activated Scope
      def start_active_span(
        operation_name,
        child_of: nil,
        references: nil,
        start_time: Time.now,
        tags: nil,
        ignore_active_scope: false,
        finish_on_close: true
      )

        # When meant to automatically determine the parent,
        # Use the active scope first, otherwise fall back to any
        # context generated by Datadog, so as to append to it and gain
        # the benefit of any out-of-the-box tracing from Datadog preceding
        # the OpenTracer::Tracer.
        #
        # We do this here instead of in #start_span because #start_span generates
        # spans that are not assigned to a scope, a.k.a not supposed to be used by
        # subsequent spans implicitly. By using the existing Datadog context, the span
        # effectively ends up "assigned to a scope", by virtue of being added to the
        # Context. Hence, it would behave more like an active span, which is why it
        # should only be here.
        unless child_of || ignore_active_scope
          child_of = if scope_manager.active
                       scope_manager.active.span.context
                     else
                       SpanContextFactory.build(datadog_context: datadog_tracer.send(:call_context))
                     end
        end

        # Create the span, and auto-add it to the Datadog context.
        span = start_span(
          operation_name,
          child_of: child_of,
          references: references,
          start_time: start_time,
          tags: tags,
          ignore_active_scope: ignore_active_scope
        )

        # Overwrite the tracer context with the OpenTracing managed context.
        # This is mostly for the benefit of any out-of-the-box tracing from Datadog,
        # such that spans generated by that tracing will be attached to the OpenTracer
        # parent span.
        datadog_tracer.provider.context = span.context.datadog_context

        scope_manager.activate(span, finish_on_close: finish_on_close).tap do |scope|
          if block_given?
            begin
              yield(scope)
            ensure
              scope.close
            end
          end
        end
      end

      # Like {#start_active_span}, but the returned {Span} has not been registered via the
      # {ScopeManager}.
      #
      # @param operation_name [String] The operation name for the Span
      # @param child_of [SpanContext, Span] SpanContext that acts as a parent to
      #   the newly-started Span. If a Span instance is provided, its
      #   context is automatically substituted. See [Reference] for more
      #   information.
      #   If specified, the `references` parameter must be omitted.
      # @param references [Array<Reference>] An array of reference
      #   objects that identify one or more parent SpanContexts.
      # @param start_time [Time] When the Span started, if not now
      # @param tags [Hash] Tags to assign to the Span at start time
      # @param ignore_active_scope [Boolean] whether to create an implicit
      #   References#CHILD_OF reference to the ScopeManager#active.
      # @return [Span] the newly-started Span instance, which has not been
      #   automatically registered via the ScopeManager
      def start_span(
        operation_name,
        child_of: nil,
        references: nil,
        start_time: Time.now,
        tags: nil,
        ignore_active_scope: false
      )

        # Derive the OpenTracer::SpanContext to inherit from.
        parent_span_context = inherited_span_context(child_of, ignore_active_scope: ignore_active_scope)

        # Retrieve Datadog::Context from parent SpanContext.
        datadog_context = parent_span_context.nil? ? Datadog::Tracing::Context.new : parent_span_context.datadog_context
        datadog_trace_digest = parent_span_context && parent_span_context.datadog_trace_digest

        # Build the new Datadog span
        datadog_span = datadog_tracer.trace(
          operation_name,
          continue_from: datadog_trace_digest,
          _context: datadog_context,
          start_time: start_time,
          tags: tags || {}
        )

        # Build or extend the OpenTracer::SpanContext
        span_context = if parent_span_context
                         SpanContextFactory.clone(span_context: parent_span_context)
                       else
                         SpanContextFactory.build(datadog_context: datadog_context)
                       end

        # Wrap the Datadog span and OpenTracer::Span context in a OpenTracer::Span
        Span.new(datadog_span: datadog_span, span_context: span_context)
      end

      # Inject a {SpanContext} into the given carrier.
      #
      # @param span_context [SpanContext]
      # @param format [OpenTracing::FORMAT_TEXT_MAP, OpenTracing::FORMAT_BINARY, OpenTracing::FORMAT_RACK]
      # @param carrier [Carrier] A carrier object of the type dictated by the specified `format`
      def inject(span_context, format, carrier)
        case format
        when OpenTracing::FORMAT_TEXT_MAP
          TextMapPropagator.inject(span_context, carrier)
        when OpenTracing::FORMAT_BINARY
          BinaryPropagator.inject(span_context, carrier)
        when OpenTracing::FORMAT_RACK
          RackPropagator.inject(span_context, carrier)
        else
          warn 'Unknown inject format'
        end
      end

      # Extract a {SpanContext} in the given format from the given carrier.
      #
      # @param format [OpenTracing::FORMAT_TEXT_MAP, OpenTracing::FORMAT_BINARY, OpenTracing::FORMAT_RACK]
      # @param carrier [Carrier] A carrier object of the type dictated by the specified `format`
      # @return [SpanContext, nil] the extracted SpanContext or nil if none could be found
      def extract(format, carrier)
        case format
        when OpenTracing::FORMAT_TEXT_MAP
          TextMapPropagator.extract(carrier)
        when OpenTracing::FORMAT_BINARY
          BinaryPropagator.extract(carrier)
        when OpenTracing::FORMAT_RACK
          RackPropagator.extract(carrier)
        else
          warn 'Unknown extract format'
          nil
        end
      end

      private

      def inherited_span_context(parent, ignore_active_scope: false)
        case parent
        when Span
          parent.context
        when SpanContext
          parent
        else
          ignore_active_scope ? nil : scope_manager.active && scope_manager.active.span.context
        end
      end
    end
  end
end
