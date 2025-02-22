# Copyright 2024 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

require "digest/md5"
require "forwardable"
require "graphql"
require "elastic_graph/constants"
require "elastic_graph/errors"
require "elastic_graph/graphql/monkey_patches/schema_field"
require "elastic_graph/graphql/monkey_patches/schema_object"
require "elastic_graph/graphql/schema/field"
require "elastic_graph/graphql/schema/type"
require "elastic_graph/support/hash_util"

module ElasticGraph
  # Wraps a GraphQL::Schema object in order to provide higher-level, more convenient APIs
  # on top of that. The schema is assumed to be immutable, so this class memoizes many
  # computations it does, ensuring we never need to traverse the schema graph multiple times.
  class GraphQL
    class Schema
      BUILT_IN_TYPE_NAMES = (
        scalar_types = ::GraphQL::Schema::BUILT_IN_TYPES.keys # Int, ID, String, etc
        introspection_types = ::GraphQL::Schema.types.keys # __Type, __Schema, etc
        scalar_types.to_set.union(introspection_types)
      )

      attr_reader :element_names, :defined_types, :config, :graphql_schema, :runtime_metadata

      def initialize(
        graphql_schema_string:,
        config:,
        runtime_metadata:,
        index_definitions_by_graphql_type:,
        graphql_gem_plugins:,
        &build_resolver
      )
        @element_names = runtime_metadata.schema_element_names
        @config = config
        @runtime_metadata = runtime_metadata

        @types_by_graphql_type = Hash.new do |hash, key|
          hash[key] = Type.new(
            self,
            key,
            index_definitions_by_graphql_type[key.graphql_name] || [],
            runtime_metadata.object_types_by_name[key.graphql_name],
            runtime_metadata.enum_types_by_name[key.graphql_name]
          )
        end

        @types_by_name = Hash.new { |hash, key| hash[key] = lookup_type_by_name(key) }
        @build_resolver = build_resolver

        # Note: as part of loading the schema, the GraphQL gem may use the resolver (such
        # when a directive has a custom scalar) so we must wait to instantiate the schema
        # as late as possible here. If we do this before initializing some of the instance
        # variables above we'll get `NoMethodError` on `nil`.
        @graphql_schema = ::GraphQL::Schema.from_definition(
          graphql_schema_string,
          default_resolve: LazyResolverAdapter.new(method(:resolver)),
          using: graphql_gem_plugins
        )

        # Pre-load all defined types so that all field extras can get configured as part
        # of loading the schema, before we execute the first query.
        @defined_types = build_defined_types_array(@graphql_schema)
      end

      def type_from(graphql_type)
        @types_by_graphql_type[graphql_type]
      end

      # Note: this does not support "wrapped" types (e.g. `Int!` or `[Int]` compared to `Int`),
      # as the graphql schema object does not give us an index of those by name. You can still
      # get type objects for wrapped types, but you need to get it from a field object of that
      # type.
      def type_named(type_name)
        @types_by_name[type_name.to_s]
      end

      def document_type_stored_in(index_definition_name)
        indexed_document_types_by_index_definition_name.fetch(index_definition_name) do
          if index_definition_name.include?(ROLLOVER_INDEX_INFIX_MARKER)
            raise ArgumentError, "`#{index_definition_name}` is the name of a rollover index; pass the name of the parent index definition instead."
          else
            raise Errors::NotFoundError, "The index definition `#{index_definition_name}` does not appear to exist. Is it misspelled?"
          end
        end
      end

      def field_named(type_name, field_name)
        type_named(type_name).field_named(field_name)
      end

      def enum_value_named(type_name, enum_value_name)
        type_named(type_name).enum_value_named(enum_value_name)
      end

      # The list of user-defined types that are indexed document types. (Indexed aggregation types will not be included in this.)
      def indexed_document_types
        @indexed_document_types ||= defined_types.select(&:indexed_document?)
      end

      def to_s
        "#<#{self.class.name} 0x#{__id__.to_s(16)} indexed_document_types=#{indexed_document_types.map(&:name).sort.to_s.delete(":")}>"
      end
      alias_method :inspect, :to_s

      private

      # Adapter class to allow us to lazily load the resolver instance.
      #
      # Necessary because the resolver must be provided to `GraphQL::Schema.from_definition`,
      # but the resolver logic itself depends upon the loaded schema to know how to resolve.
      # To work around the circular dependency, we build the schema with this lazy adapter,
      # then build the resolver with the schema, and then the lazy resolver lazily loads the resolver.
      LazyResolverAdapter = Struct.new(:builder) do
        def resolver
          @resolver ||= builder.call
        end

        extend Forwardable
        def_delegators :resolver, :call, :resolve_type, :coerce_input, :coerce_result
      end

      def lookup_type_by_name(type_name)
        type_from(@graphql_schema.types.fetch(type_name))
      rescue KeyError => e
        msg = "No type named #{type_name} could be found"
        msg += "; Possible alternatives: [#{e.corrections.join(", ").delete('"')}]." if e.corrections.any?
        raise Errors::NotFoundError, msg
      end

      def resolver
        @resolver ||= @build_resolver.call(self)
      end

      def build_defined_types_array(graphql_schema)
        graphql_schema
          .types
          .values
          .reject { |t| BUILT_IN_TYPE_NAMES.include?(t.graphql_name) }
          .map { |t| type_named(t.graphql_name) }
      end

      def indexed_document_types_by_index_definition_name
        @indexed_document_types_by_index_definition_name ||= indexed_document_types.each_with_object({}) do |type, hash|
          type.index_definitions.each do |index_def|
            if hash.key?(index_def.name)
              raise Errors::SchemaError, "DatastoreCore::IndexDefinition #{index_def.name} is used multiple times: #{type} vs #{hash[index_def.name]}"
            end

            hash[index_def.name] = type
          end
        end.freeze
      end
    end
  end
end
