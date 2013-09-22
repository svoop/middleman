require 'tilt'
require 'active_support/core_ext/string/output_safety'
require 'middleman-core/template_context'
require 'middleman-core/file_renderer'
require 'middleman-core/contracts'

module Middleman
  class TemplateRenderer
    extend Forwardable
    include Contracts

    def self.cache
      @_cache ||= ::Tilt::Cache.new
    end

    def_delegator :"self.class", :cache

    # Custom error class for handling
    class TemplateNotFound < RuntimeError; end

    def initialize(app, path)
      @app = app
      @path = path
    end

    # Render a template, with layout, given a path
    #
    # @param [Hash] locs
    # @param [Hash] opts
    # @return [String]
    Contract Hash, Hash => String
    def render(locs={}, opts={})
      path = @path.dup
      locals = locs.dup.freeze
      options = opts.dup

      extension = File.extname(path)
      engine = extension[1..-1].to_sym

      if defined?(::I18n)
        old_locale = ::I18n.locale
        ::I18n.locale = options[:lang] if options[:lang]
      end

      # Sandboxed class for template eval
      context = @app.template_context_class.new(@app, locals, options)

      # TODO: Only for HAML files
      context.init_haml_helpers if context.respond_to?(:init_haml_helpers)

      # Keep rendering template until we've used up all extensions. This
      # handles cases like `style.css.sass.erb`
      content = nil
      while ::Tilt[path]
        begin
          options[:template_body] = content if content

          content_renderer = ::Middleman::FileRenderer.new(@app, path)
          content = content_renderer.render(locals, options, context)

          path = File.basename(path, File.extname(path))
        rescue LocalJumpError
          raise "Tried to render a layout (calls yield) at #{path} like it was a template. Non-default layouts need to be in #{source}/#{@app.config[:layouts_dir]}."
        end
      end

      # If we need a layout and have a layout, use it
      if layout_path = fetch_layout(engine, options)
        layout_renderer = ::Middleman::FileRenderer.new(@app, layout_path)
        content = layout_renderer.render(locals, options, context) { content }
      end

      # Return result
      content
    ensure
      # Pop all the saved variables from earlier as we may be returning to a
      # previous render (layouts, partials, nested layouts).
      ::I18n.locale = old_locale if defined?(::I18n)
    end

    protected

    # Find a layout for a given engine
    #
    # @param [Symbol] engine
    # @param [Hash] opts
    # @return [String, Boolean]
    Contract Symbol, Hash => Or[String, Bool]
    def fetch_layout(engine, opts)
      # The layout name comes from either the system default or the options
      local_layout = opts.key?(:layout) ? opts[:layout] : @app.config[:layout]
      return false unless local_layout

      # Look for engine-specific options
      engine_options = @app.config.respond_to?(engine) ? @app.config.send(engine) : {}

      # The engine for the layout can be set in options, engine_options or passed
      # into this method
      layout_engine = if opts.key?(:layout_engine)
        opts[:layout_engine]
      elsif engine_options.key?(:layout_engine)
        engine_options[:layout_engine]
      else
        engine
      end

      # Automatic mode
      if local_layout == :_auto_layout
        # Look for :layout of any extension
        # If found, use it. If not, continue
        locate_layout(:layout, layout_engine) || false
      else
        # Look for specific layout
        # If found, use it. If not, error.
        if layout_path = locate_layout(local_layout, layout_engine)
          layout_path
        else
          raise ::Middleman::TemplateRenderer::TemplateNotFound, "Could not locate layout: #{local_layout}"
        end
      end
    end

    # Find a layout on-disk, optionally using a specific engine
    # @param [String] name
    # @param [Symbol] preferred_engine
    # @return [String]
    Contract Or[String, Symbol], Symbol => Maybe[String]
    def locate_layout(name, preferred_engine=nil)
      self.class.locate_layout(@app, name, preferred_engine)
    end

    # Find a layout on-disk, optionally using a specific engine
    # @param [String] name
    # @param [Symbol] preferred_engine
    # @return [String]
    Contract IsA['Middleman::Application'], Or[String, Symbol], Symbol => Maybe[String]
    def self.locate_layout(app, name, preferred_engine=nil)
      resolve_opts = {}
      resolve_opts[:preferred_engine] = preferred_engine unless preferred_engine.nil?

      # Check layouts folder
      layout_path = resolve_template(app, File.join(app.config[:layouts_dir], name.to_s), resolve_opts)

      # If we didn't find it, check root
      layout_path = resolve_template(app, name, resolve_opts) unless layout_path

      # Return the path
      layout_path
    end

    # Find a template on disk given a output path
    # @param [String] request_path
    # @param [Hash] options
    # @return [Array<String, Symbol>, Boolean]
    Contract String, Hash => ArrayOf[Or[String, Symbol]]
    def resolve_template(request_path, options={})
      self.class.resolve_template(@app, request_path, options)
    end

    # Find a template on disk given a output path
    # @param [String] request_path
    # @option options [Boolean] :preferred_engine If set, try this engine first, then fall back to any engine.
    # @return [String, Boolean] Either the path to the template, or false
    Contract IsA['Middleman::Application'], Or[Symbol, String], Hash => Maybe[String]
    def self.resolve_template(app, request_path, options={})
      # Find the path by searching or using the cache
      request_path = request_path.to_s
      cache.fetch(:resolve_template, request_path, options) do
        relative_path = Util.strip_leading_slash(request_path)
        on_disk_path  = File.expand_path(relative_path, app.source_dir)

        # By default, any engine will do
        preferred_engines = ['*']
        preferred_engines << nil if options[:try_static]

        # If we're specifically looking for a preferred engine
        if options.key?(:preferred_engine)
          extension_class = ::Tilt[options[:preferred_engine]]

          # Get a list of extensions for a preferred engine
          matched_exts = ::Tilt.mappings.select do |_, engines|
            engines.include? extension_class
          end.keys

          # Prefer to look for the matched extensions
          unless matched_exts.empty?
            preferred_engines.unshift('{' + matched_exts.join(',') + '}')
          end
        end

        search_paths = preferred_engines.map do |preferred_engine|
          path_with_ext = on_disk_path.dup
          path_with_ext << ('.' + preferred_engine) unless preferred_engine.nil?
          path_with_ext
        end

        found_path = nil
        search_paths.each do |path_with_ext|
          found_path = Dir[path_with_ext].find do |path|
            ::Tilt[path]
          end

          unless found_path
            found_path = path_with_ext if File.exist?(path_with_ext)
          end

          break if found_path
        end

        # If we found one, return it
        if found_path
          found_path
        elsif File.exist?(on_disk_path)
          on_disk_path
        else
          nil
        end
      end
    end
  end
end