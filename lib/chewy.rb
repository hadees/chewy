require 'active_support'
require 'active_support/log_subscriber'
require 'active_support/deprecation'
require 'active_support/core_ext'
require 'active_support/concern'
require 'active_support/json'
require 'i18n/core_ext/hash'
require 'chewy/backports/deep_dup' unless Object.respond_to?(:deep_dup)
require 'singleton'

require 'elasticsearch'

require 'chewy/version'
require 'chewy/errors'
require 'chewy/config'
require 'chewy/repository'
require 'chewy/runtime'
require 'chewy/log_subscriber'
require 'chewy/strategy'
require 'chewy/index'
require 'chewy/type'
require 'chewy/fields/base'
require 'chewy/fields/root'
require 'chewy/railtie' if defined?(::Rails)

begin
  require 'kaminari'
  require 'chewy/query/pagination/kaminari'
rescue LoadError
end

begin
  require 'will_paginate'
  require 'will_paginate/collection'
  require 'chewy/query/pagination/will_paginate'
rescue LoadError
end

ActiveSupport.on_load(:active_record) do
  extend Chewy::Type::Observe::ActiveRecordMethods

  begin
    require 'will_paginate/active_record'
  rescue LoadError
  end
end

ActiveSupport.on_load(:mongoid) do
  module Mongoid::Document::ClassMethods
    include Chewy::Type::Observe::MongoidMethods
  end

  begin
    require 'will_paginate/mongoid'
    require 'chewy/query/pagination/will_paginate'
  rescue LoadError
  end
end

module Chewy
  class << self
    # Derives type from string `index#type` representation:
    #
    #   Chewy.derive_type('users#user') # => UsersIndex::User
    #
    # If index has only one type - it is possible to derive it without specification:
    #
    #   Chewy.derive_type('users') # => UsersIndex::User
    #
    # If index has more then one type - it raises Chewy::UnderivableType.
    #
    def derive_type name
      return name if name.is_a?(Class) && name < Chewy::Type

      index_name, type_name = name.split('#', 2)
      class_name = "#{index_name.camelize}Index"
      index = class_name.safe_constantize
      raise Chewy::UnderivableType.new("Can not find index named `#{class_name}`") unless index && index < Chewy::Index
      type = if type_name.present?
        index.type_hash[type_name] or raise Chewy::UnderivableType.new("Index `#{class_name}` doesn`t have type named `#{type_name}`")
      elsif index.types.one?
        index.types.first
      else
        raise Chewy::UnderivableType.new("Index `#{class_name}` has more than one type, please specify type via `#{index_name}#type_name`")
      end
    end

    # Creates Chewy::Type ancestor defining index and adapter methods.
    #
    def create_type index, target, options = {}, &block
      type = Class.new(Chewy::Type)

      options = options.with_indifferent_access
      adapter_class = options.delete(:adapter)
      adapter = adapter_class.new(target, options) if adapter_class

      adapter ||= if defined?(::ActiveRecord::Base) && ((target.is_a?(Class) && target < ::ActiveRecord::Base) || target.is_a?(::ActiveRecord::Relation))
        Chewy::Type::Adapter::ActiveRecord.new(target, options)
      elsif defined?(::Mongoid::Document) && ((target.is_a?(Class) && target.ancestors.include?(::Mongoid::Document)) || target.is_a?(::Mongoid::Criteria))
        Chewy::Type::Adapter::Mongoid.new(target, options)
      else
        Chewy::Type::Adapter::Object.new(target, options)
      end
      
      index.const_set(adapter.name, type)
      type.send(:define_singleton_method, :index) { index }
      type.send(:define_singleton_method, :adapter) { adapter }

      type.class_eval &block if block
      type
    end

    # Main elasticsearch-ruby client instance
    #
    def client
      Thread.current[:chewy_client] ||= ::Elasticsearch::Client.new configuration
    end

    # Sends wait_for_status request to ElasticSearch with status
    # defined in configuration.
    #
    # Does nothing in case of config `wait_for_status` is undefined.
    #
    def wait_for_status
      client.cluster.health wait_for_status: Chewy.configuration[:wait_for_status] if Chewy.configuration[:wait_for_status].present?
    end

    # Deletes all corresponding indexes with current prefix from ElasticSearch.
    # Be careful, if current prefix is blank, this will destroy all the indexes.
    #
    def massacre
      Chewy.client.indices.delete(index: [Chewy.configuration[:prefix], '*'].delete_if(&:blank?).join(?_))
      Chewy.wait_for_status
    end
    alias_method :delete_all, :massacre

    # Strategies are designed to allow nesting, so it is possible
    # to redefine it for nested contexts.
    #
    #   Chewy.strategy(:atomic) do
    #     city1.do_update!
    #     Chewy.strategy(:urgent) do
    #       city2.do_update!
    #       city3.do_update!
    #       # there will be 2 update index requests for city2 and city3
    #     end
    #     city4..do_update!
    #     # city1 and city4 will be grouped in one index update request
    #   end
    #
    # It is possible to nest strategies without blocks:
    #
    #   Chewy.strategy(:urgent)
    #   city1.do_update! # index updated
    #   Chewy.strategy(:bypass)
    #   city2.do_update! # update bypassed
    #   Chewy.strategy.pop
    #   city3.do_update! # index updated again
    #
    def strategy name = nil, &block
      Thread.current[:chewy_strategy] ||= Chewy::Strategy.new
      if name
        if block
          Thread.current[:chewy_strategy].wrap name, &block
        else
          Thread.current[:chewy_strategy].push name
        end
      else
        Thread.current[:chewy_strategy]
      end
    end

    def urgent_update= value
      ActiveSupport::Deprecation.warn('`Chewy.urgent_update = value` is deprecated and will be removed soon, use `Chewy.strategy(:urgent)` block instead')
      if value
        strategy(:urgent)
      else
        strategy.pop
      end
    end

    def atomic &block
      ActiveSupport::Deprecation.warn('`Chewy.atomic` block is deprecated and will be removed soon, use `Chewy.strategy(:atomic)` block instead')
      strategy(:atomic, &block)
    end

    def config
      Chewy::Config.instance
    end
    delegate *Chewy::Config.delegated, to: :config

    def repository
      Chewy::Repository.instance
    end
    delegate *Chewy::Repository.delegated, to: :repository
  end
end
