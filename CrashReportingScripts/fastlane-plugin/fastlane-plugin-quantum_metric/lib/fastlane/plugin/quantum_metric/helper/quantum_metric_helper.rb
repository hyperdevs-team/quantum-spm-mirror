require 'net/http'
require 'uri'
require 'tempfile'
require 'json'

module Fastlane
  module Helper
    class QuantumMetricHelper
      MAX_DSYM_SIZE = 2 * 1024 * 1024 * 1024 # 2 GB
      MAX_RETRIES = 3
      RETRY_BASE_DELAY = 1 # seconds

      class ServerError < StandardError; end

      # Resolve and expand dSYM paths.
      # Accepts .dSYM directories, .zip files, and .xcarchive directories.
      # Returns an array of paths (each a .dSYM dir or .zip file).
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

      # Zip a .dSYM directory using ditto.
      # Returns the path to the created zip file (in a temp directory).
      def self.zip_dsym(dsym_path)
        dsym_name = File.basename(dsym_path)
        tmp_dir = Dir.mktmpdir('qm_dsym')
        zip_path = File.join(tmp_dir, "#{dsym_name}.zip")

        UI.message("Zipping #{dsym_name}...")
        result = Actions.sh(
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

      # Extract UUIDs from a dSYM bundle using dwarfdump.
      # If given a .zip, extracts to a temp directory first.
      # Returns an array of UUID strings (uppercase, with hyphens).
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

      # Upload a zipped dSYM to the Quantum Metric API.
      # Returns a hash with :uuid, :status_code, :success, :dsym_path, :body.
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

      # Parse dwarfdump --uuid output into an array of UUID strings.
      def self.parse_dwarfdump_uuids(output)
        return [] if output.nil? || output.empty?

        output.scan(/UUID:\s+([0-9A-Fa-f-]{36})/).flatten.map(&:upcase)
      end

      # Extract UUIDs from a zipped dSYM by unzipping to a temp directory.
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
end
