# ElasticsearchRecord - CHANGELOG

## [1.4.0] - 2023-01-27
* [add] `ElasticsearchRecord::ModelApi` for fast & easy access the elasticsearch index - callable through `.api` (e.g. ElasticUser.api.mappings)
* [ref] `ElasticsearchRecord::Instrumentation::LogSubscriber` to truncate the query-string (default: 1000)
* [ref] `ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#log` with extra attribute (log: true) to prevent logging (e.g. on custom api calls)
* [fix] `ElasticsearchRecord::Result#bucket` to prevent resolving additional meta key (key_as_string)

## [1.3.1] - 2023-01-18
* [fix] `#none!` method to correctly invalidate the query (String(s) in where-queries like '1=0' will raise now)
* [fix] missing 'ChangeSettingDefinition' & 'RemoveSettingDefinition' @ `ActiveRecord::ConnectionAdapters::Elasticsearch::UpdateTableDefinition::COMPOSITE_DEFINITIONS` to composite in a single query
* [fix] `#unblock_table`-method in 'connection' to now remove blocks instead of setting to 'false'

## [1.3.0] - 2023-01-17
* [add] 'metas: {}' param for `CreateTableDefinition` to provide individual meta information without providing them through 'mappings'
* [add] 'change_'- & 'remove_'-methods for _mapping, setting & alias_  for `CreateTableDefinition`
* [add] `ActiveRecord::ConnectionAdapters::Elasticsearch::TableMappingDefinition#meta` for easier access
* [add] `UpdateTableDefinition#remove_mapping` to always raise an ArgumentError (now created @ `CreateTableDefinition` through change_table(x, recreate: true) )
* [add] `_env_table_name`-syntax to `ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper#table` for prefixed & suffixed tables in connections
* [add] `#cluster_health`, `#refresh_table`, `#refresh_tables` & `#rename_table` methods to 'connection'
* [add] `#change_table` 'recreate: false' parameter to switch between a 'change' or 'recreate' of an index
* [add] `#refresh` method to relations to explicit set the refresh value of the generated query
* [ref] `CloneTableDefinition` to adapt settings (number_of_shards & number_of_replicas) from source table by default
* [ref] `CreateTableDefinition#transform_mappings!` also support simple 'key->attributes' assignment of custom provided mappings
* [ref] 'delete_'-methods into more common 'remove_'  for `UpdateTableDefinition`
* [ref] `UpdateTableDefinition#change_mapping` to always raise an ArgumentError (now moved to `CreateTableDefinition` through change_table(x, recreate: true) )
* [ref] `#change_table` missing '&block'
* [ref] 'delete_'-methods into more common 'remove_' to 'connection'
* [ref] ':\_\_claim\_\_'-operator to ':\_\_query\_\_' within `Arel::Collectors::ElasticsearchQuery`
* [ref] update & delete queries to preset a 'refresh: true' as default _(can be overwritten through 'relation.refresh(false)' )_
* [rem] `#clone_table` unusable '&block'
* [rem] `#compute_table_name`-method - must be explicit provided with `#_env_table_name(name)`
* [fix] `#where!` & `#build_where_clause` methods to also build a valid 'where_clause' in nested 'where' & 'or'

## [1.2.4] - 2022-12-15
* [fix] missing `#visit_Arel_Nodes_In` method in `Arel::Visitors::ElasticsearchQuery` to build array conditions
* [fix] resolving buckets from relation `ElasticsearchRecord::Result#buckets` not recognizing sub-buckets

## [1.2.3] - 2022-12-12
* [fix] `change_table` 'if_exists: true' returns at the wrong state

## [1.2.2] - 2022-12-12
* [add] `:if_exists` option for `change_table`
* [fix] executing `_compute_table_name` irregular on some schema methods and some not - not only executes on `create_table` and `change_table`
* [ref] private `_compute_table_name` method to public `compute_table_name`
* [ref] drop `_compute_table_name` on methods: open_table, close_table, truncate_table, drop_table, block_table, unblock_table & clone_table

## [1.2.1] - 2022-12-12
* [add] `ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements#access_id_fielddata?` which checks the clusters setting 'indices.id_field_data.enabled' to determinate if a general sorting on the +_id+-field is possible or not.
* [add] `ElasticsearchRecord::Relation#ordered_relation` which overwrites the original method to check against the `#access_id_fielddata?` method
* [fix] default order by '_id' causes an exception if clusters 'indices.id_field_data.enabled' is disabled
* [fix] subfield where-condition `where('field.subfield', 'value')` was transformed into a nested 'join-table' hash
* [fix] yardoc docs & generation

## [1.2.0] - 2022-12-02
* [add] `ElasticsearchRecord::SchemaMigration` to fix connection-related differences (like table_name_prefix, table_name_suffix)
* [add] connection (config-related) 'table_name_prefix' & 'table_name_suffix' - now will be forwarded to all related models & schema-tables
* [add] `#block_table`, `#unblock_table`, `#clone_table`, `#table_metas`, `#meta_exists?`, `#change_meta`, `#delete_meta` methods for Elasticsearch ConnectionAdapter
* [add] `ElasticsearchRecord::Base.auto_increment?`
* [add] index 'meta' method to access the `_meta` mapping
* [add] `.ElasticsearchRecord::Base.relay_id_attribute` to relay a possible existing 'id'-attribute
* [add] new enabled attribute `enabled` - which defines 'searchable attributes & fields' and gets also read from the index-mappings
* [ref] insert a new record with primary_key & auto_increment through a wrapper `_insert_with_auto_increment`
* [ref] resolve `primary_keys` now from the index `_meta` mapping first (old mapping-related 'meta.primary_key:"true"' is still supported)
* [ref] disable 'strict' mode (= validation) of settings, alias, mappings as default (this can be still used with `strict: true`)
* [ref] silent unsupported methods 'create/drop' for `ElasticsearchRecord::Tasks::ElasticsearchDatabaseTasks`
* [ref] primary_key & auto_increment handling of custom defined mappings - now uses the index `_meta` mapping
* [fix] creating a record with different 'primary_key' fails with removed value (value no longer gets dropped)
* [fix] some index-settings not being ignored through `#transform_settings!`
* [fix] `ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper` dumping environment-related tables in the same database
* [fix] `ActiveRecord::ConnectionAdapters::Elasticsearch::TableMappingDefinition` fails with explicit assignable attributes (now uses ASSIGNABLE_ATTRIBUTES)
* [fix] tables with provided 'table_name_prefix' or 'table_name_suffix' not being ignored by the SchemaDumper

## [1.1.0] - 2022-12-01
* [add] support for schema dumps & migrations for Elasticsearch
* [add] `buckets` query/relation result method to resolve the buckets as key->value hash from aggregations
* [add] support for third-party gems (e.g. elasticsearch-dsl)
* [add] custom primary_key support with 'auto_increment' adaption _(beta)_
* [ref] instrumentation of `LogSubscriber` coloring
* [ref] unsupported methods to show exception
* [ref] query/relation method `#msearch` to support options 'resolve', 'transpose' & 'keep_null_relation'
* [ref] `ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#translate_exception` for better error handling
* [ref] `ActiveRecord::ConnectionAdapters::Elasticsearch::Column` for a much easier assignment
* [ref] gemspec, yardoc & docs
* [fix] `ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::BASE_STRUCTURE` to force primary_key column '_id' as virtual
* [fix] `ElasticsearchRecord::Relation::QueryClauseTree` not correctly calculating & merging 'filters, musts, ... '
* [fix] failing query not really failing in nested queries (msearch) 
* [fix] 'null_realation' being executed in msearch
* [fix] quoting of columns, attributes & values
* [fix] query/relation method `#count` not preventing 'null_relation?'

## [1.0.2] - 2022-11-07
* [add] `ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#migrations_paths` with 'db/migrate_elasticsearch'
* [fix] to prevent executing 'primary' migrations to elasticsearch (SchemaDumper may still throw error comments)
* [add] temporary workarounds for scheme & migrations until we support it (so bin/rails db:migrate - tasks will now run again)

## [1.0.1] - 2022-10-19
* [add] `ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Nested` class to cast nested values
* [add] **properties** to column definition (so they are also searchable by _Relation_ conditions)
* [add] exception for _Relation_ #pit_results if batch size is too large
* [add] a default _#find_by_id_-method to proved a 'fallback' functionality for the primary '_id' column
* [fix] nested properties are not cast for column-type "object"
* [fix] `ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements` fields and property detection
* [fix] `ElasticsearchRecord::StatementCache::PartialQuery` reference manipulation of cached hash _(missing .deep_dup )_
* [ref] `ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object` class to only cast object values
* [ref] `Arel::Visitors::Elasticsearch#visit_Sort` to detect a random sort with correct keyword: "**\_\_rand\_\_**"

## [1.0.0] - 2022-10-18
* [add] patch for `ActiveRecord::Relation::Merger` - to support AR-relations
* [add] `ElasticsearchRecord::Relation#pit_results` _offset_ & _yield_ support
* [add] individual instrumentation names for `ElasticsearchRecord::Relation` result methods (like: #aggregations)
* [rem] cleanup Debugging & logging
* [fix] quoting for any values
* [fix] calculation `count` method to support already known syntax (with column, distinct, limited, ...)
* [fix] `Arel::Nodes` to support additional args (query, kind, aggs, ...)
* [fix] _relation manager patch_ to not mash up different relations
* [fix] `ElasticsearchRecord` total calculation for failed queries
* [fix] `ElasticsearchRecord::Relation#count` to correctly _unscope_
* [fix] `Arel::Visitors::Elasticsearch`
  * build query where-clauses without existing default query-"kind" 
  * directly fail if a grouping _(visit_Arel_Nodes_Grouping)_ was provided
  * forced _failed!_ state was not correctly claimed
  * buggy _assign_-method for nested arrays
* [fix] `Arel::Collectors::ElasticsearchQuery`
  * claim for _argument_
  * delete key on _nil_ assign
* [ref] simplify `Arel::Collectors::ElasticsearchQuery` (remove stack & scoping)
* [ref] simplify `Arel::Visitors::Elasticsearch` to support binds (statement cache) and simple where predicates
* [ref] rename `ElasticsearchRecord::Query#arguments` -> _#query_arguments_

## [0.1.2] - 2022-09-23
* [fix] Records / Elasticsearch index with additional 'id' fields not recognizing
* [rem] unnecessary & overcomplicated .index_name_delimiter class attribute

## [0.1.1] - 2022-09-22
* [add] msearch for klass & relation
* [fix] Gemfile (remove duplicated requirements)
* [fix] gemspec (dependencies & descriptions)
* [fix] loading requirements, remove unused code
* [fix] quoting
* [fix] arel collector
* [fix] arel visitor sort & assignment
* [ref] results builder for multiple responses
* [ref] log_subscriber to hide index but show 'query time'
* [ref] model_schema attributes

## [0.1.0] - 2022-09-21
* Initial commit
* docs, version, structure
