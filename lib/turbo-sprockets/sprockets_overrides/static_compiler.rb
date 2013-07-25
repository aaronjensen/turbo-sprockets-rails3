begin
  require 'sprockets/static_compiler'
rescue LoadError
end

require 'parallel'

# Sprockets::StaticCompiler was only introduced in Rails 3.2.x
if defined?(Sprockets::StaticCompiler)
  module Sprockets
    StaticCompiler.class_eval do
      def initialize(env, target, paths, options = {})
        @env = env
        @target = target
        @paths = paths
        @digest = options.fetch(:digest, true)
        @manifest = options.fetch(:manifest, true)
        @manifest_path = options.delete(:manifest_path) || target
        @zip_files = options.delete(:zip_files) || /\.(?:css|html|js|svg|txt|xml)$/

        @current_source_digests = options.fetch(:source_digests, {})
        @current_digests        = options.fetch(:digests,   {})

        @digests        = {}
        @source_digests = {}
      end

      def compile
        start_time = Time.now.to_f

        logical_paths = []
        logical_paths = env.each_logical_path(paths).to_a

        results = Parallel.map(logical_paths, in_processes: ENV.fetch("PARALLEL_SPROCKETS_PROCESSORS", Parallel.processor_count).to_i) do |logical_path|
          result = {}
          # Fetch asset without any processing or compression,
          # to calculate a digest of the concatenated source files
          #puts "LOOK #{Process.pid}  #{Thread.current.inspect} #{logical_path}"
          next unless asset = env.find_asset(logical_path, :process => false)
          result[:asset_digest] = asset_digest = asset.digest
          result[:logical_path] = logical_path

          # Recompile if digest has changed or compiled digest file is missing
          current_digest_file = @current_digests[logical_path]

          if asset_digest != @current_source_digests[logical_path] ||
             !(current_digest_file && File.exists?("#{@target}/#{current_digest_file}"))

            if asset = env.find_asset(logical_path)
              result[:asset_logical_path] = asset.logical_path
              result[:digest_path] = write_asset(asset)
              result[:asset_digest_path] = asset.digest_path
            end
          else
            # Set asset file from manifest.yml
            result[:logical_path] = logical_path
            digest_path = @current_digests[logical_path]

            env.logger.debug "Not compiling #{logical_path}, sources digest has not changed " <<
                             "(#{asset_digest[0...7]})"
          end

          result
        end

        results.compact.each do |result|
          asset_logical_path = result[:asset_logical_path]
          logical_path = asset_logical_path || result[:logical_path]
          @source_digests[logical_path] = result[:asset_digest]

          digest_path = result[:digest_path] || @current_digests[logical_path]
          @digests[logical_path] = digest_path
          @digests[aliased_path_for(logical_path)] = digest_path
          # Update current_digests with new hash, for future assets to reference
          if result[:asset_digest_path]
            @current_digests[asset_logical_path] = result[:asset_digest_path]
          end
        end

        # Encode all filenames & digests as UTF-8 for Ruby 1.9,
        # otherwise YAML dumps other string encodings as !binary
        if RUBY_VERSION.to_f >= 1.9
          @source_digests = encode_hash_as_utf8 @source_digests
          @digests        = encode_hash_as_utf8 @digests
        end

        if @manifest
          write_manifest(@digests)
          write_sources_manifest(@source_digests)
        end

        # Store digests in Rails config. (Important if non-digest is run after primary)
        config = ::Rails.application.config
        config.assets.digests        = @digests
        config.assets.source_digests = @source_digests

        elapsed_time = ((Time.now.to_f - start_time) * 1000).to_i
        env.logger.debug "Processed #{'non-' unless @digest}digest assets in #{elapsed_time}ms"
      end

      def write_sources_manifest(source_digests)
        FileUtils.mkdir_p(@manifest_path)
        File.open("#{@manifest_path}/sources_manifest.yml", 'wb') do |f|
          YAML.dump(source_digests, f)
        end
      end

      private

      def encode_hash_as_utf8(hash)
        Hash[*hash.map {|k,v| [k.encode("UTF-8"), v.encode("UTF-8")] }.flatten]
      end
    end
  end
end
