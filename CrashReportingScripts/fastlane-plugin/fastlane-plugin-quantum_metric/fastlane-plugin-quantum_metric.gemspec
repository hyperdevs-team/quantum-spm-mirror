lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fastlane/plugin/quantum_metric/version'

Gem::Specification.new do |spec|
  spec.name          = 'fastlane-plugin-quantum_metric'
  spec.version       = Fastlane::QuantumMetric::VERSION
  spec.authors       = ['Quantum Metric']
  spec.email         = ['support@quantummetric.com']

  spec.summary       = 'Upload iOS dSYM files to Quantum Metric for crash symbolication'
  spec.description   = 'Fastlane plugin that uploads dSYM symbolication files to Quantum Metric ' \
                        'so that crash reports can be symbolicated with human-readable function names ' \
                        'and line numbers. Supports .dSYM directories, .zip archives, and .xcarchive bundles.'
  spec.homepage      = 'https://github.com/nicetoreplyto/fastlane-plugin-quantum_metric'
  spec.license       = 'MIT'

  spec.files         = Dir['lib/**/*'] + %w[README.md LICENSE]
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.6'

  spec.add_dependency 'fastlane', '>= 2.0.0'

  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'pry'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'webmock'
end
