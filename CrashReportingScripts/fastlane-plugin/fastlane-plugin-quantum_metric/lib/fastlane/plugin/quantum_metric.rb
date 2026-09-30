require 'fastlane/plugin/quantum_metric/version'

module Fastlane
  module QuantumMetric
    def self.all_classes
      Dir[File.expand_path('quantum_metric/actions/*.rb', File.dirname(__FILE__))]
    end
  end
end
