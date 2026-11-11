# Quantum Metric — Upload dSYM to Quantum Metric (Standalone Action)
#
# Drop this file into your project's fastlane/actions/ directory.
# No gem installation required.
#
# Alternatively, install the gem: gem 'fastlane-plugin-quantum_metric'
#
# Usage in Fastfile:
#   upload_dsym_to_quantum_metric(
#     api_key: ENV["QM_API_KEY"],
#     dsym_path: "./build/MyApp.app.dSYM",
#     app_id: "com.example.myapp",
#     app_version: "2.1.0"
#   )

require 'net/http'
require 'uri'
require 'tempfile'
require 'json'

module Fastlane
  module Helper
    class QuantumMetricHelper
      MAX_DSYM_SIZE = 2 * 1024 * 1024 * 1024 # 2 GB
      MAX_RETRIES = 3
      RETRY_BASE_DELAY = 1

      class ServerError < StandardError; end

      def self.find_dsym_files(paths)
        resolved = []

        Array(paths).each do |path|
          path = File.expand_path(path)

          unless File.exist?(path)
            UI.error("dSYM path does not exist: #{path}")
            next
          end

          if path.end_with?('.xcarchive')
            dsyms = Dir.glob(File.join(path, 'dSYMs', '*.dSYM'))
            if dsyms.empty?
              UI.error("No dSYMs found in xcarchive: #{path}")
            else
              resolved.concat(dsyms)
            end
          elsif path.end_with?('.dSYM') && File.directory?(path)
            resolved << path
          elsif path.end_with?('.zip') && File.file?(path)
            resolved << path
          else
            UI.error("Unsupported dSYM path (expected .dSYM, .zip, or .xcarchive): #{path}")
          end
        end

        resolved
      end

      def self.zip_dsym(dsym_path)
        dsym_name = File.basename(dsym_path)
        tmp_dir = Dir.mktmpdir('qm_dsym')
        zip_path = File.join(tmp_dir, "#{dsym_name}.zip")

        UI.message("Zipping #{dsym_name}...")
        Actions.sh(
          'ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
          dsym_path, zip_path,
          log: false,
          error_callback: ->(_) {}
        )

        unless File.exist?(zip_path) && File.size(zip_path) > 0
          UI.user_error!("Failed to zip dSYM: #{dsym_path}")
        end

        zip_path
      end

      def self.extract_uuids(dsym_or_zip_path)
        if dsym_or_zip_path.end_with?('.zip')
          return extract_uuids_from_zip(dsym_or_zip_path)
        end

        dwarf_dir = File.join(dsym_or_zip_path, 'Contents', 'Resources', 'DWARF')
        unless File.directory?(dwarf_dir)
          UI.error("No DWARF directory found in #{dsym_or_zip_path}")
          return []
        end

        binaries = Dir.glob(File.join(dwarf_dir, '*'))
        if binaries.empty?
          UI.error("No binaries found in DWARF directory: #{dwarf_dir}")
          return []
        end

        uuids = []
        binaries.each do |binary|
          output = Actions.sh('dwarfdump', '--uuid', binary, log: false, error_callback: ->(_) {})
          parse_dwarfdump_uuids(output).each { |uuid| uuids << uuid }
        end

        uuids.uniq
      end

      def self.upload_dsym(zip_path:, uuid:, api_key:, app_id:, app_version:, platform:, base_url:, sub: nil)
        file_size = File.size(zip_path)
        if file_size >= MAX_DSYM_SIZE
          return { uuid: uuid, status_code: nil, success: false, dsym_path: zip_path,
                   body: "File too large (#{file_size} bytes, max #{MAX_DSYM_SIZE})" }
        end

        # `sub` (subscription) is optional and only appended when present. The
        # backend uses it to route the upload to that subscription's home
        # region; omit it and the upload lands in whatever region receives it
        # (US by default). Query-param order mirrors the Android uploader:
        # app_id, app_version, sub, platform.
        form = { 'app_id' => app_id, 'app_version' => app_version }
        form['sub'] = sub if sub && !sub.to_s.strip.empty?
        form['platform'] = platform
        encoded_params = URI.encode_www_form(form)
        url = "#{base_url}/crash-analytics/symbols/v1/#{uuid}?#{encoded_params}"
        uri = URI.parse(url)

        attempt = 0
        begin
          attempt += 1

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == 'https')
          http.read_timeout = 300
          http.open_timeout = 30

          request = Net::HTTP::Put.new(uri.request_uri)
          request['Authorization'] = "Api-key #{api_key}"
          request['Content-Type'] = 'application/zip'
          request['Content-Length'] = file_size.to_s

          File.open(zip_path, 'rb') do |file|
            request.body_stream = file
            request.content_length = file_size

            response = http.request(request)

            result = {
              uuid: uuid,
              status_code: response.code.to_i,
              success: response.code.to_i == 200,
              dsym_path: zip_path,
              body: response.body
            }

            if response.code.to_i == 200
              UI.success("Uploaded dSYM #{uuid}")
            elsif [401, 403].include?(response.code.to_i)
              UI.user_error!("Authentication failed (HTTP #{response.code}). Check your API key.")
            elsif response.code.to_i >= 500 && attempt < MAX_RETRIES
              raise ServerError, "Server error #{response.code}"
            else
              UI.error("Upload failed for #{uuid} (HTTP #{response.code}): #{response.body}")
            end

            return result
          end
        rescue ServerError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
          if attempt < MAX_RETRIES
            delay = RETRY_BASE_DELAY * (2**(attempt - 1))
            UI.message("Retrying upload for #{uuid} in #{delay}s (attempt #{attempt}/#{MAX_RETRIES})...")
            sleep(delay)
            retry
          end

          UI.error("Upload failed for #{uuid} after #{MAX_RETRIES} attempts: #{e.message}")
          return { uuid: uuid, status_code: nil, success: false, dsym_path: zip_path, body: e.message }
        end
      end

      def self.parse_dwarfdump_uuids(output)
        return [] if output.nil? || output.empty?

        output.scan(/UUID:\s+([0-9A-Fa-f-]{36})/).flatten.map(&:upcase)
      end

      def self.extract_uuids_from_zip(zip_path)
        tmp_dir = Dir.mktmpdir('qm_dsym_unzip')
        Actions.sh('ditto', '-x', '-k', zip_path, tmp_dir, log: false, error_callback: ->(_) {})

        dsym_dirs = Dir.glob(File.join(tmp_dir, '**', '*.dSYM'))
        if dsym_dirs.empty?
          UI.error("No .dSYM found inside zip: #{zip_path}")
          FileUtils.rm_rf(tmp_dir)
          return []
        end

        uuids = []
        dsym_dirs.each do |dsym_dir|
          extract_uuids(dsym_dir).each { |uuid| uuids << uuid }
        end

        FileUtils.rm_rf(tmp_dir)
        uuids.uniq
      end
    end
  end

  module Actions
    module SharedValues
      QUANTUM_METRIC_DSYM_UPLOAD_RESULTS = :QUANTUM_METRIC_DSYM_UPLOAD_RESULTS
    end

    class UploadDsymToQuantumMetricAction < Action
      def self.run(params)
        helper = Helper::QuantumMetricHelper

        dsym_paths = resolve_dsym_paths(params)
        if dsym_paths.nil? || dsym_paths.empty?
          UI.user_error!("No dSYM paths provided. Set dsym_path, dsym_paths, or ensure a prior action set DSYM_PATHS / DSYM_OUTPUT_PATH.")
        end

        api_key = params[:api_key]
        app_id = resolve_app_id(params)
        app_version = resolve_app_version(params)
        platform = params[:platform]
        base_url = params[:base_url].chomp('/')
        sub = resolve_sub(params)

        UI.message("Uploading dSYMs to Quantum Metric (#{base_url})")
        UI.message("  app_id: #{app_id}, app_version: #{app_version}, platform: #{platform}, sub: #{sub || '(none)'}")

        resolved_paths = helper.find_dsym_files(dsym_paths)
        if resolved_paths.empty?
          UI.user_error!("No valid dSYM files found in provided paths: #{dsym_paths.join(', ')}")
        end

        UI.message("Found #{resolved_paths.count} dSYM(s) to upload")

        results = []
        temp_zips = []

        resolved_paths.each do |dsym_path|
          if dsym_path.end_with?('.zip')
            zip_path = dsym_path
          else
            zip_path = helper.zip_dsym(dsym_path)
            temp_zips << zip_path
          end

          uuids = helper.extract_uuids(dsym_path)
          if uuids.empty?
            UI.error("Could not extract UUID from #{dsym_path}, skipping")
            results << { uuid: nil, status_code: nil, success: false, dsym_path: dsym_path, body: 'No UUID found' }
            next
          end

          uuids.each do |uuid|
            UI.message("Uploading #{File.basename(dsym_path)} (#{uuid})...")
            result = helper.upload_dsym(
              zip_path: zip_path,
              uuid: uuid,
              api_key: api_key,
              app_id: app_id,
              app_version: app_version,
              platform: platform,
              base_url: base_url,
              sub: sub
            )
            results << result.merge(dsym_path: dsym_path)
          end
        end

        temp_zips.each do |path|
          dir = File.dirname(path)
          FileUtils.rm_rf(dir) if dir.include?('qm_dsym')
        end

        lane_context[SharedValues::QUANTUM_METRIC_DSYM_UPLOAD_RESULTS] = results

        successes = results.count { |r| r[:success] }
        failures = results.count { |r| !r[:success] }

        UI.success("Successfully uploaded #{successes} dSYM(s) to Quantum Metric") if successes > 0

        if failures > 0
          failed_uuids = results.reject { |r| r[:success] }.map { |r| r[:uuid] || 'unknown' }.join(', ')
          if successes == 0
            UI.user_error!("All #{failures} dSYM upload(s) failed. UUIDs: #{failed_uuids}")
          else
            UI.important("#{failures} dSYM upload(s) failed. UUIDs: #{failed_uuids}")
          end
        end

        results
      end

      def self.description
        'Upload dSYM symbolication files to Quantum Metric for crash reporting'
      end

      def self.details
        'Uploads iOS dSYM files to Quantum Metric so that crash reports can be symbolicated ' \
        'with human-readable function names and line numbers. Supports .dSYM directories, ' \
        '.dSYM.zip archives, and .xcarchive bundles.'
      end

      def self.authors
        ['Quantum Metric']
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(
            key: :dsym_path,
            env_name: 'QM_DSYM_PATH',
            description: 'Path to a single .dSYM directory or .dSYM.zip file',
            optional: true,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :dsym_paths,
            env_name: 'QM_DSYM_PATHS',
            description: 'Array of paths to .dSYM directories, .zip files, or .xcarchive bundles',
            optional: true,
            type: Array
          ),
          FastlaneCore::ConfigItem.new(
            key: :api_key,
            env_name: 'QM_API_KEY',
            description: 'Quantum Metric API key (from Integrations page in QM UI)',
            sensitive: true,
            optional: false,
            type: String,
            verify_block: proc do |value|
              UI.user_error!("API key must not be empty") if value.to_s.strip.empty?
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :app_id,
            env_name: 'QM_APP_ID',
            description: 'App bundle identifier (defaults to Appfile app_identifier)',
            optional: true,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :app_version,
            env_name: 'QM_APP_VERSION',
            description: 'App version string (defaults to VERSION_NUMBER from lane context)',
            optional: true,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :platform,
            env_name: 'QM_PLATFORM',
            description: 'Platform identifier',
            optional: true,
            default_value: 'iOS',
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :sub,
            env_name: 'QM_SUB',
            description: 'QM subscription (the "sub" you init the SDK with). Optional — routes ' \
                         'the upload to that subscription\'s home region; omit it and the upload ' \
                         'lands in whatever region receives it (US by default)',
            optional: true,
            type: String
          ),
          FastlaneCore::ConfigItem.new(
            key: :base_url,
            env_name: 'QM_BASE_URL',
            description: 'Quantum Metric API base URL (override for staging or EU regions)',
            optional: true,
            default_value: 'https://api.quantummetric.com',
            type: String
          )
        ]
      end

      def self.output
        [
          ['QUANTUM_METRIC_DSYM_UPLOAD_RESULTS',
           'Array of hashes with :uuid, :status_code, :success, :dsym_path, :body for each upload']
        ]
      end

      def self.return_type
        :array
      end

      def self.return_value
        'Array of upload result hashes'
      end

      def self.is_supported?(platform)
        platform == :ios
      end

      def self.example_code
        [
          'upload_dsym_to_quantum_metric(
            api_key: "your-api-key",
            dsym_path: "./build/MyApp.app.dSYM"
          )',
          'build_app(scheme: "MyApp")
          upload_dsym_to_quantum_metric(
            api_key: ENV["QM_API_KEY"],
            app_id: "com.example.myapp",
            app_version: "2.1.0"
          )'
        ]
      end

      def self.category
        :testing
      end

      def self.resolve_dsym_paths(params)
        if params[:dsym_paths] && !params[:dsym_paths].empty?
          return params[:dsym_paths]
        end

        if params[:dsym_path]
          return [params[:dsym_path]]
        end

        if defined?(SharedValues::DSYM_PATHS)
          context_paths = lane_context[SharedValues::DSYM_PATHS]
          return context_paths if context_paths && !context_paths.empty?
        end

        if defined?(SharedValues::DSYM_OUTPUT_PATH)
          output_path = lane_context[SharedValues::DSYM_OUTPUT_PATH]
          return [output_path] if output_path
        end

        nil
      end

      def self.resolve_app_id(params)
        return params[:app_id] if params[:app_id]

        begin
          appfile_id = CredentialsManager::AppfileConfig.try_fetch_value(:app_identifier)
          if appfile_id
            UI.message("Using app_id from Appfile: #{appfile_id}")
            return appfile_id
          end
        rescue StandardError
          # CredentialsManager may not be available
        end

        UI.user_error!("app_id is required. Set it via the app_id parameter, QM_APP_ID env var, or Appfile.")
      end

      def self.resolve_app_version(params)
        return params[:app_version] if params[:app_version]

        context_version = lane_context[SharedValues::VERSION_NUMBER]
        if context_version
          UI.message("Using app_version from lane context: #{context_version}")
          return context_version
        end

        UI.user_error!("app_version is required. Set it via the app_version parameter, QM_APP_VERSION env var, or use get_version_number before this action.")
      end

      # `sub` (subscription) is optional. ConfigItem already applies the QM_SUB
      # env fallback; here we normalize blank/whitespace to nil and warn — an
      # absent sub never fails the upload, it just means non-US symbols may be
      # routed to the wrong region (matches the Android plugin's behavior).
      def self.resolve_sub(params)
        sub = params[:sub]
        sub = nil if sub.nil? || sub.to_s.strip.empty?
        if sub.nil?
          UI.important("QM 'sub' not set. Set the `sub` parameter or QM_SUB env var to the subscription you init the SDK with; otherwise symbols for a non-US subscription may upload to the wrong region and crashes may not symbolicate.")
        end
        sub
      end

      private_class_method :resolve_dsym_paths, :resolve_app_id, :resolve_app_version, :resolve_sub
    end
  end
end
