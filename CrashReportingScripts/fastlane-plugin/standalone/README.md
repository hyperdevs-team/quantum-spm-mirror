# Quantum Metric dSYM Upload — Standalone Action

A single-file fastlane action for uploading dSYM files to Quantum Metric. No gem required.

## Installation

Copy `upload_dsym_to_quantum_metric_action.rb` into your project's `fastlane/actions/` directory:

```bash
cp upload_dsym_to_quantum_metric_action.rb /path/to/your/project/fastlane/actions/
```

## Usage

In your `Fastfile`:

```ruby
lane :upload_symbols do
  upload_dsym_to_quantum_metric(
    api_key: ENV["QM_API_KEY"],
    dsym_path: "./build/MyApp.app.dSYM",
    app_id: "com.example.myapp",
    app_version: "2.1.0",
    sub: "your-sub"
  )
end
```

See the [plugin README](../fastlane-plugin-quantum_metric/README.md) for full parameter documentation.
