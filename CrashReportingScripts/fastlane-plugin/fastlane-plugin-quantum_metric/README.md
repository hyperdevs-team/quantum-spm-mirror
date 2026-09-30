# fastlane-plugin-quantum_metric

Upload iOS dSYM symbolication files to Quantum Metric for crash reporting.

## Installation

Add to your project's `Gemfile`:

```ruby
gem 'fastlane-plugin-quantum_metric'
```

Or install via fastlane:

```bash
fastlane add_plugin quantum_metric
```

## Usage

```ruby
# Basic usage — upload a single dSYM
upload_dsym_to_quantum_metric(
  api_key: ENV["QM_API_KEY"],
  dsym_path: "./build/MyApp.app.dSYM",
  app_id: "com.example.myapp",
  app_version: "2.1.0",
  sub: "your-sub"
)

# After gym/build_app — dSYMs are picked up automatically from lane context
build_app(scheme: "MyApp")
upload_dsym_to_quantum_metric(
  api_key: ENV["QM_API_KEY"],
  app_id: "com.example.myapp",
  app_version: "2.1.0"
)

# Upload all dSYMs from an xcarchive
upload_dsym_to_quantum_metric(
  api_key: ENV["QM_API_KEY"],
  dsym_paths: ["./build/MyApp.xcarchive"],
  app_id: "com.example.myapp",
  app_version: "2.1.0"
)

# Upload a pre-zipped dSYM
upload_dsym_to_quantum_metric(
  api_key: ENV["QM_API_KEY"],
  dsym_path: "./build/MyApp.app.dSYM.zip",
  app_id: "com.example.myapp",
  app_version: "2.1.0"
)
```

## Parameters

| Key | Env Var | Required | Default | Description |
|-----|---------|----------|---------|-------------|
| `dsym_path` | `QM_DSYM_PATH` | No* | — | Path to a `.dSYM` directory or `.dSYM.zip` file |
| `dsym_paths` | `QM_DSYM_PATHS` | No* | Lane context | Array of `.dSYM`, `.zip`, or `.xcarchive` paths |
| `api_key` | `QM_API_KEY` | **Yes** | — | API key from QM Integrations page |
| `app_id` | `QM_APP_ID` | No | Appfile `app_identifier` | Bundle identifier |
| `app_version` | `QM_APP_VERSION` | No | Lane context `VERSION_NUMBER` | App version string |
| `platform` | `QM_PLATFORM` | No | `iOS` | Platform identifier |
| `sub` | `QM_SUB` | No | — | QM subscription (the "sub" you init the SDK with). Routes the upload to that subscription's home region; if omitted the upload lands in whatever region receives it (US by default) and a warning is logged |
| `base_url` | `QM_BASE_URL` | No | `https://api.quantummetric.com` | API base URL |

\* At least one of `dsym_path`, `dsym_paths`, or a prior action setting `DSYM_PATHS` / `DSYM_OUTPUT_PATH` is required.

## Output

The action sets `QUANTUM_METRIC_DSYM_UPLOAD_RESULTS` in the lane context — an array of hashes, each containing:

- `uuid` — The dSYM UUID that was uploaded
- `status_code` — HTTP response code
- `success` — Boolean
- `dsym_path` — Path to the source dSYM
- `body` — Response body

## How It Works

1. Resolves dSYM paths (expands `.xcarchive` bundles, accepts `.dSYM` dirs and `.zip` files)
2. Extracts UUIDs from each dSYM using `dwarfdump --uuid`
3. Zips `.dSYM` directories using `ditto` (preserves macOS resource forks)
4. Uploads each zipped dSYM to `PUT /crash-analytics/symbols/v1/:uuid?app_id=…&app_version=…&sub=…&platform=…` (the `sub` param is included only when set)
5. Retries server errors (5xx) up to 3 times with exponential backoff

## License

MIT
