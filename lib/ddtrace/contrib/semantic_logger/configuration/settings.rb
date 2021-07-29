require 'ddtrace/contrib/configuration/settings'
require 'ddtrace/contrib/semantic_logger/ext'

module Datadog
  module Contrib
    module SemanticLogger
      module Configuration
        # Custom settings for the SemanticLogger integration
        class Settings < Contrib::Configuration::Settings
          option :enabled do |o|
            o.default { env_to_bool(Ext::ENV_ENABLED, true) }
            o.lazy
          end
        end
      end
    end
  end
end
