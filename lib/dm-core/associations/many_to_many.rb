module DataMapper
  module Associations
    module ManyToMany #:nodoc:
      class Relationship < Associations::OneToMany::Relationship
        ##
        # Returns a set of keys that identify the target model
        #
        # @return [DataMapper::PropertySet]
        #   a set of properties that identify the target model
        #
        # @api semipublic
        def child_key
          @child_key ||=
            begin
              properties = target_model.properties(target_repository_name)

              child_key = if @child_properties
                properties.values_at(*@child_properties)
              else
                properties.key
              end

              properties.class.new(child_key).freeze
            end
        end

        alias target_key child_key

        # TODO: document
        # @api semipublic
        def through
          return @through if @through != Resource

          # habtm relationship traversal is deferred because we want the
          # target_model and source_model constants to be defined, so we
          # can define the join model within their common namespace

          DataMapper.repository(source_repository_name) do
            many_to_one = join_model.belongs_to(join_relationship_name(target_model),          :model => target_model, :nullable => false)
            one_to_many = source_model.has(min..max, join_relationship_name(join_model, true), :model => join_model)

            # initialize the child_key on the many to one relationship
            # now that the source, join and target models are defined
            many_to_one.child_key

            @through = one_to_many
          end
        end

        # TODO: document
        # @api semipublic
        def links
          @links ||=
            begin
              relationships = through.target_model.relationships(source_repository_name)

              unless target = relationships[name] || relationships[name.to_s.singular.to_sym]
                raise NameError, "Cannot find target relationship #{name} or #{name.to_s.singular} in #{through.target_model} within the #{source_repository_name.inspect} repository"
              end

              [ through, target ].map { |r| (l = r.links).any? ? l : r }.flatten.freeze
            end
        end

        # TODO: document
        # @api private
        def source_scope(source)
          # TODO: remove this method and inherit from Relationship

          target_key = through.target_key
          source_key = through.source_key

          scope = {}

          # TODO: handle compound keys
          if (source_values = Array(source).map { |r| source_key.first.get(r) }.compact).any?
            scope[target_key.first] = source_values
          end

          scope
        end

        # TODO: document
        # @api private
        def query
          # TODO: consider making this a query_for method, so that ManyToMany::Relationship#query only
          # returns the query supplied in the definition

          @many_to_many_query ||=
            begin
              # TODO: make sure the proper Query is set up, one that includes all the links
              #   - make sure that all relationships can be links
              #   - make sure that each intermediary can be at random repositories
              #   - make sure that each intermediary can have different conditons that
              #     scope its results

              query = super.dup

              # use all links in the query links
              query[:links] = links

              # TODO: move the logic below inside Query.  It should be
              # extracting the query conditions from each relationship itself

              repository_name = source_repository_name

              # merge the conditions from each intermediary into the query
              query[:links].each do |relationship|
                repository_name = relationship.target_repository_name || repository_name
                model           = relationship.target_model

                # TODO: try to do some of this normalization when
                # assigning the Query options to the Relationship

                relationship.query.each do |key, value|
                  # TODO: figure out how to merge Query options from links
                  if Query::OPTIONS.include?(key)
                    next  # skip for now
                  end

                  case key
                    when Symbol, String
                      # TODO: turn this into a Query::Path
                      query[model.properties(repository_name)[key]] = value

                    when Property
                      # TODO: turn this into a Query::Path
                      query[key] = value

                    when Query::Path
                      query[key] = value

                    when Query::Operator
                      # TODO: if the key.target is a Query::Path, then do not look it up
                      query[key.class.new(model.properties(repository_name)[key.target], key.operator)] = value

                    else
                      raise ArgumentError, "#{key.class} not allowed in relationship query"
                  end
                end
              end

              query.freeze
            end
        end

        private

        # TODO: document
        # @api private
        def join_model
          namespace, name = join_model_namespace_name

          if namespace.const_defined?(name)
            namespace.const_get(name)
          else
            model = Model.new do
              # all properties added to the anonymous join model are considered a key
              def property(name, type, options = {})
                options[:key] = true unless options.key?(:key)
                options.delete(:index)
                super
              end
            end

            namespace.const_set(name, model)
          end
        end

        # TODO: document
        # @api private
        def join_model_namespace_name
          target_parts = target_model.base_model.name.split('::')
          source_parts = source_model.base_model.name.split('::')

          name = [ target_parts.pop, source_parts.pop ].sort.join

          namespace = Object

          # find the common namespace between the target_model and source_model
          target_parts.zip(source_parts) do |target_part, source_part|
            break if target_part != source_part
            namespace = namespace.const_get(target_part)
          end

          return namespace, name
        end

        # TODO: document
        # @api private
        def join_relationship_name(model, plural = false)
          namespace = join_model_namespace_name.first
          relationship_name = Extlib::Inflection.underscore(model.base_model.name.sub(/\A#{namespace.name}::/, '')).gsub('/', '_')
          (plural ? relationship_name.plural : relationship_name).to_sym
        end

        # TODO: document
        # @api private
        def inverse
          raise NotImplementedError, "#{self.class}#inverse not implemented"
        end

        # Returns collection class used by this type of
        # relationship
        #
        # @api private
        def collection_class
          ManyToMany::Collection
        end
      end # class Relationship

      class Collection < Associations::OneToMany::Collection
        # TODO: document
        # @api public
        def create(attributes = {})
          assert_source_saved 'The source must be saved before creating a Resource'

          resource = create_intermediaries(attributes, relationship.links.dup).last
          self << resource if resource.saved?
          resource
        end

        # TODO: document
        # @api public
        def save
          resources = if loaded?
            entries
          else
            head + tail
          end

          last_relationship = relationship.links.last

          # delete only intermediaries linked to the target orphans
          intermediaries.each do |intermediary|
            next unless @orphans.include?(last_relationship.get(intermediary))
            intermediaries.delete(intermediary) if intermediary.destroy
          end

          # ensure all intermediaries are saved so that using first_or_new
          # below actually finds previously added Resources, rather than
          # creating duplicate records
          return false unless intermediaries.save

          # TODO: this handles the case where the through resource is dependent
          # on the target being created, but probably will not handle the case where
          # the target is dependent on the through resource.  TEST THIS OUT
          #   - can this case can occur where a many to many is through a belongs_to?

          if last_relationship.kind_of?(Associations::ManyToOne::Relationship)
            resources.all? do |resource|
              if resource.save
                # create the intermediary record if there isn't one already
                intermediaries.first_or_create(last_relationship => resource)
              end
            end
          else
            # XXX: would this be used for has n through a belongs_to?

            intermediary = intermediaries.first_or_create
            inverse      = last_relationship.inverse

            return false unless intermediary.save

            resources.map do |resource|
              inverse.set(resource, intermediary)
            end

            super
          end
        end

        # TODO: document
        # @api public
        def destroy
          unless intermediaries.destroy
            return false
          end

          super
        end

        # TODO: document
        # @api public
        def destroy!
          unless intermediaries.destroy!
            return false
          end

          if empty?
            return true
          end

          # FIXME: use a subquery to do this more efficiently in the future
          repository_name = relationship.target_repository_name
          model           = relationship.target_model
          key             = model.key(repository_name)

          # TODO: handle compound keys
          model.all(:repository => repository_name, key.first => map { |r| r.key.first }).destroy!

          each { |r| r.reset }
          clear

          true
        end

        private

        def _update(dirty_attributes)
          attributes = dirty_attributes.map { |p, v| [ p.name, v ] }.to_hash

          # FIXME: use a subquery to do this more efficiently in the future,
          key = model.key(repository.name)

          # TODO: handle compound keys
          model.all(:repository => repository_name, key.first => map { |r| r.key.first }).update!(attributes)
        end

        def intermediaries
          through           = relationship.through
          last_relationship = relationship.links.last

          intermediaries = through.loaded?(source) ? through.get!(source) : through.collection_for(source)
          intermediaries = intermediaries.all(last_relationship => self)
        end

        # TODO: attempt to refactor this method out using an approach
        # similar to #save to create intermediaries
        def create_intermediaries(attributes, links)
          attributes = default_attributes.merge(attributes)

          head = [ source ]
          tail = []

          lhs, rhs = nil, nil

          until links.empty?
            if links[1].kind_of?(ManyToOne::Relationship) || (links.size == 1 && lhs && rhs)
              lhs, rhs = links.first(2) unless lhs && rhs

              relationship = links.pop

              resource = if tail.empty?
                # create the target resource
                model = relationship.target_model
                model.create(attributes)
              elsif relationship == lhs
                # create the join resource
                collection = lhs.get(head.last)
                collection.first_or_create(rhs => tail.first)
              else
                # create each resource linking the target and join resources
                collection = relationship.inverse.get(tail.first)
                collection.first_or_create
              end

              tail.unshift(resource)
            else
              relationship = links.shift

              collection = relationship.get(head.last)

              if links.empty?
                # create the target resource
                head << collection.create(attributes)
              else
                # create each resource linking to the previous resource
                head << collection.first_or_create
              end
            end
          end

          head + tail
        end

        # TODO: document
        # @api private
        def relate_resource(resource)
          collection_relate_resource(resource)
        end

        # TODO: document
        # @api private
        def orphan_resource(resource)
          collection_orphan_resource(resource)
        end

        # TODO: document
        # @api private
        def delegate_to_relationship(relationship, other_query = nil)
          # FIXME: add support for SEL to m:m

          query = relationship.query_for(self)
          query.update(other_query) if other_query

          model.all(query)
        end

      end # class Collection
    end # module ManyToMany
  end # module Associations
end # module DataMapper
