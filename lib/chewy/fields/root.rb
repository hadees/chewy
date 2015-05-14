module Chewy
  module Fields
    class Root < Chewy::Fields::Base
      attr_reader :dynamic_templates
      attr_reader :id
      attr_reader :parent
      attr_reader :parent_id
      attr_reader :routing

      def initialize(*args)
        super(*args)

        @id = @options.delete(:id) || options.delete(:_id)
        @parent = @options.delete(:parent) || options.delete(:_parent)
        @parent_id = @options.delete(:parent_id)
        @routing = @options.delete(:routing) || options.delete(:_routing)
        @routing = { value: -> { self.call(@routing) } } if @routing.is_a?(Symbol)
        @value ||= ->(_) { _ }
        @dynamic_templates = []
        @options.delete(:type)
      end

      def mappings_hash
        mappings = super
        mappings[name].delete(:type)

        if dynamic_templates.any?
          mappings[name][:dynamic_templates] ||= []
          mappings[name][:dynamic_templates].concat dynamic_templates
        end

        mappings[name][:_parent] = parent.is_a?(Hash) ? parent : { type: parent } if parent
        mappings[name][:_routing] = routing.select {|k,v| k.to_sym != :value } if routing.is_a?(Hash)
        mappings
      end

      def dynamic_template *args
        options = args.extract_options!.deep_symbolize_keys
        if args.first
          template_name = :"template_#{dynamic_templates.count.next}"
          template = {template_name => {mapping: options}}

          template[template_name][:match_mapping_type] = args.second.to_s if args.second.present?

          regexp = args.first.is_a?(Regexp)
          template[template_name][:match_pattern] = 'regexp' if regexp

          match = regexp ? args.first.source : args.first
          path = match.include?(regexp ? '\.' : '.')

          template[template_name][path ? :path_match : :match] = match
          @dynamic_templates.push(template)
        else
          @dynamic_templates.push(options)
        end
      end

      def compose_parent(object)
        if parent_id
          parent_id.arity == 0 ? object.instance_exec(&parent_id) : parent_id.call(object)
        end
      end

      def compose_routing(object)
        return if !routing.is_a?(Hash)
        value = routing[:value] 
        value.arity == 0 ? object.instance_exec(&value) : value.call(object)
      end

      def compose_id(object)
        if id
          id.arity == 0 ? object.instance_exec(&id) : id.call(object)
        end
      end
    end
  end
end
