# ElasticsearchRecord  :: rails-7-1-stable - CHANGELOG

## [PATCH] - 2026-09-08
* [fix] `Querying::ClassMethods#search` to nest the `Elasticsearch::DSL` block result into the `body` and to only enter the DSL branch **if a block was provided**

## [2.0.0] - 2026-08-10
* [add] `ElasticsearchRecord.decorate_table_names` _(default: `true`)_ as global kill-switch for the table name decoration - only provides the default for an omitted `decorate:`-argument, `#_env_table_name` stays unaffected
* [add] `TableStatements#truncate_table` raises an `ArgumentError` for AR-internal indices - the statement runs a `drop` & `create` and would wipe the migration state. `#drop_table` stays unguarded by design _(AR resets both tables through it)_
* [add] `QueryMethods#select` raises on metadata fields _(`_id`, `_score`, ...)_ - they are always returned anyway
* [add] `ElasticsearchRecord::Result` now resolves **tabular** responses _(`sql`: columns + rows, `esql`: columns + values)_, so `find_by_sql` _(String)_ & `find_by_esql` instantiate records - rows are zipped against the **response** columns
* [add] `CalculationMethods#matrix_stats` raises an `ArgumentError` for less than two columns - the metric quantifies the relationship **between** fields
* [add] `ResultMethods#meta_only!` to resolve the metadata nodes _(`_id`, `_score`, ...)_ of each hit without transferring the `_source`
* [add] `Query::COLUMNS_NONE` constant for the `'!'` projection marker - replaces the bare literal in `visit_Selects` & `meta_only!`
* [add] specs for `ElasticsearchRecord::Persistence`, `ModelApi`, `SchemaMigration`, `Querying::ClassMethods`, the `Relation` methods _(Core, Query, Calculation & Result)_, the `Elasticsearch::SchemaStatements`, `TableStatements` & `SchemaDumper`, every class of the `Elasticsearch::Type` namespace _(incl. its `TYPE_MAP` registration)_, `Arel::Collectors::ElasticsearchQuery` and all three `Arel::Visitors::Elasticsearch*` visitors - incl. the 1.8.1 "only ten migrations" and 1.8.2 nested-reset regressions and a `TestIndexWithAutoIncrement` support that builds a model against a real `auto_increment` schema _(destructive calls still run through `TestIndex` and its name guard)_. Behaviours pinned as-is:
  * `#or` compiles into a **failed** query _(the visitor fails every `Arel::Nodes::Grouping`)_, and AR's blank-arg stripping silently drops `configure(key, nil)` _(only the Hash form removes a key)_
  * an index **alias** is dumped as a mapping of the elasticsearch 'alias' field type, which makes the `t.alias` branch of the dumper unreachable
  * opposed nil-handling of metas _(deleted)_ and settings _(kept through `:__force__`)_
  * a failed `create` has no `FAILED_BODIES` entry and falls back to an empty body; a multi-column `order` keeps only the last sort
  * `SchemaMigration#count` and `#delete_version` / `#delete_all_versions` cannot be served by elasticsearch
  * `_update_record` / `_delete_record` always return `0` _(a document-API response carries no `total`)_, and an auto-incremented id is only written as document `_id`, never into the mapped primary-key field
  * `meta_only!` **spawns** instead of mutating the receiver _(unlike the other bang methods)_ and pins the `COLUMNS_NONE` projection; `pit_results` pins its infinite-loop guard
* [ref] **BREAKING**: every table statement resolves its table (index) name through `#_env_table_name` **by default** - the `table_name_prefix` / `table_name_suffix` no longer have to be applied by hand, which silently wrote into another environment's index. A new `decorate:`-argument _(default: `true`)_ switches it off per call for already resolved names. Only TABLE names are decorated; schema statements stay undecorated
* [ref] `SchemaDumper#table` dumps the **base** name instead of a `_env_table_name(...)` call - if that name would not resolve back, the full name is dumped with an explicit `decorate: false`
* [ref] **BREAKING**: `#open_tables`, `#close_tables`, `#refresh_tables` & `#truncate_tables` no longer subtract the AR-internal indices _(an explicitly named index was silently dropped)_ - plain loops now, forwarding `decorate:` to their singular statement and returning an `Array` for every provided name
* [ref] `TableStatements` drops the stale `:rename_table` entry from `define_unsupported_method` - the real implementation overwrote it anyway
* [ref] `#restore_table` replaces its `open`-argument with `unblock:` _(default: true)_ - a restore clones and inherits the 'write'-block, so the table was open but **read-only**. `ModelApi#restore!` follows along
* [ref] `ResultMethods#pit_results` resolves through `ElasticsearchRecord::Result` and respects the current projection _(`ids_only` removed in favour of `meta_only!`)_
* [ref] `TestIndex` spec support to optionally create/drop a second index _(still guarded by the `ALLOWED` name check)_
* [fix] `#rename_table` to resolve both names **itself** - the `clear_data_source_cache!` and `cluster_health` calls in between were left with the undecorated name
* [fix] `#backup_table` to build the auto-generated target from the **already resolved** name _(the suffix landed behind the `-snapshot-` part)_
* [fix] `#_env_table_name` to cast prefix & suffix - an empty `table_name_prefix:` yml entry resolves to `nil` and raised a `TypeError`
* [fix] `Result#cast_values` to resolve values from the `_source` node, metadata fields from the document level
* [fix] `visit_Selects` to no longer provide metadata fields to the `_source`-filter _(never matched)_ - projects `_source: false` if only metadata is selected
* [fix] `Querying::ClassMethods#esql` & `#msearch` to dispatch through the public `exec_query` _(rails 7.1 made `internal_exec_query` private)_ - the `async:`-argument was dropped along with it
* [fix] `Querying::ClassMethods#find_by_sql` to reference the provided `sql` for `String` queries _(undefined `query_or_sql` raised a `NameError`)_
* [fix] `SchemaStatements#max_result_window` to resolve the **flat** setting key and cast it to an `Integer` _(always fell back to 10000 and broke the batch_size guards)_
* [fix] `SchemaStatements#primary_keys` to always return an `Array` _(the `_meta` branch returned a raw String)_
* [fix] `CalculationMethods#count` to apply the SQL `LIMIT n OFFSET m` semantic on the resolved total - `terminate_after` alone acts **per shard** and never fires on a count query. `#size` on an unloaded relation was affected as well
* [fix] `UpdateTableDefinition#change_mapping_attributes` to resolve the current mapping type with a **String** key _(fell back to `:object` / `:nested`, so elasticsearch rejected every mapping parameter)_
* [fix] `#restore_table` to no longer touch the backup after a `drop_backup: true` _(it no longer exists at that point)_
* [fix] `_insert_with_auto_increment` to write the **plain, integer** id into `_meta.auto_increment` - the block returns an Array of the `returning` values, which was stored as-is and raised on the NEXT insert. Now unwraps Array / Hash / plain and casts to `Integer`
* [fix] `ResultMethods#pit_delete` to no longer `select('_id')` _(rejected by the new metadata guard)_ - resolves the ids through `meta_only!`

## [1.8.2] - 2024-11-26
* [fix] `ElasticsearchRecord::Relation::QueryMethods#build_query_clause` to raise an exception on `nil` assignments
* [fix] `Arel::Visitors::ElasticsearchBase#compile` to always reset temporary assignments _(causes missing assignments after a query-build-exception)_
* [fix] `Arel::Nodes::SelectAgg` to not merge nil-values
* [add] elasticsearch mapping type _(semantic_text)_

## [1.8.1] - 2024-05-07
* [add] new elasticsearch mapping types _(percolator, geo, vector, texts, ...)_
* [ref] `ElasticsearchRecord::Relation#limit` to detect `Float::INFINITY` to also set the **max_result_window**
* [fix] `ElasticsearchRecord::SchemaMigration` only returning the first ten migrations (broke migrated migrations)
* [fix] `ElasticsearchRecord::Relation::CalculationMethods#calculate` method incompatibility - renamed to `#calculate_aggregation` (+ alias to `#calculate`)
* [fix] `ElasticsearchRecord::ModelApi#bulk` method not correctly generating data for 'delete'

## [1.8.0] - 2024-01-10
* [ref] major method & dependency refactoring for `rails 7.1` - _(Does **NOT** work with rails 7.0)_
* [add] new repository branch `rails-7-1-stable` to support different rails version
* [ref] gemspec to lock on rails 7.1

## [1.7.5] - 2024-11-26 _(no gem release)_
* [ref] `ElasticsearchRecord::Relation::QueryMethods#build_query_clause` to raise an exception instead of building an empty `QueryClause`

## [1.7.4] - 2024-11-25 _(no gem release)_
* [fix] `Arel::Visitors::ElasticsearchBase#compile` to always reset temporary assignments _(causes missing assignments after a query-build-exception)_
* [fix] `Arel::Nodes::SelectAgg` to not merge nil-values
* [fix] `ElasticsearchRecord::Relation::QueryMethods#build_query_clause` to prevent nil-Array assignment _(e.g. `[nil]` causes q query exception)_

## [1.7.3] - 2024-05-07 _(no gem release)_
* [add] new elasticsearch mapping types _(percolator, geo, vector, texts, ...)_
* [ref] `ElasticsearchRecord::Relation#limit` to detect `Float::INFINITY` to also set the **max_result_window**
* [fix] `ElasticsearchRecord::SchemaMigration` only returning the first ten migrations (broke migrated migrations)
* [fix] `ElasticsearchRecord::Relation::CalculationMethods#calculate` method incompatibility - renamed to `#calculate_aggregation` (+ alias to `#calculate`)
* [fix] `ElasticsearchRecord::ModelApi#bulk` method not correctly generating data for 'delete'

## [1.7.2] - 2024-01-10
* [ref] gemspec to lock on rails 7.0

## [1.7.1] - 2024-01-09
* [fix] `ElasticsearchRecord::Relation` calculation methods return with different nodes
* [ref] `ElasticsearchRecord::Relation#calculate` removes default value of `node`
* [ref] `ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#api` prevents inaccurate variable interpretation of `log`

## [1.7.0] - 2024-01-09
* [add] `ElasticsearchRecord::Relation#boxplot` calculation method
* [add] `ElasticsearchRecord::Relation#stats` calculation method
* [add] `ElasticsearchRecord::Relation#string_stats` calculation method
* [add] `ElasticsearchRecord::Relation#matrix_stats` calculation method
* [add] `ElasticsearchRecord::Relation#median_absolute_deviation` calculation method
* [add] `ElasticsearchRecord::Base#esql` + `ElasticsearchRecord::Base#find_by_esql` to support `ES|QL` queries
* [add] new repository branch `rails-7-0-stable` to support different rails versions
* [ref] minor code optimizations & documentation changes

## [1.6.0] - 2023-08-11
* [add] `ElasticsearchRecord::Base#undelegate_id_attribute_with` method to support a temporary 'undelegation' (used to create a new record)
* [add] `ElasticsearchRecord::Relation#timeout` to directly provide the timeout-parameter to the query
* [add] `ElasticsearchRecord.error_on_transaction`-flag to throw transactional errors (default: `false`) - this will now **IGNORE** all transactions
* [add] `ElasticsearchRecord::ModelApi` create!, clone!, rename!, backup!, restore! & reindex!-methods
* [add] `ElasticsearchRecord::Relation#pit_delete` which executes a delete query in a 'point_in_time' scope.
* [add] `ActiveRecord::ConnectionAdapters::Elasticsearch::TableStatements#backup_table` to create a backup (snapshot) of the entire table (index)
* [add] `ActiveRecord::ConnectionAdapters::Elasticsearch::TableStatements#restore_table` to restore a entire table (index)
* [add] `ActiveRecord::ConnectionAdapters::Elasticsearch::TableStatements#reindex_table` to copy documents from source to destination
* [ref] `ElasticsearchRecord::Base.delegate_id_attribute` now supports instance writer
* [ref] `ElasticsearchRecord::Relation#pit_results` adds `ids_only`-parameter to now support a simple return of the records-ids...
* [fix] Relation `#last`-method will raise an transport exception if cluster setting '**indices.id_field_data.enabled**' is disabled (now checks for `access_id_fielddata?`)
* [fix] ElasticsearchRecord-connection settings does not support `username` key
* [fix] ElasticsearchRecord-connection settings does not support `port` key
* [fix] `_id`-Attribute is erroneously defined as 'virtual' attribute - but is required for insert statements.
* [fix] unsupported **SAVEPOINT** transactions throws exceptions _(especially in tests)_
* [fix] `ElasticsearchRecord::ModelApi#bulk` does not recognize `'_id' / :_id` attribute
* [fix] `ElasticsearchRecord::ModelApi#bulk` does not correctly build the data-hash for `update`-operation _(missing 'doc'-node)_
* [ref] simplify `ElasticsearchRecord::Base#searchable_column_names`
* [fix] creating a new record does not recognize a manually provided `_id`-attribute
* [fix] creating a new record with active `delegate_id_attribute`-flag does not update the records `_id`.

## [1.5.3] - 2023-07-14
* [fix] `ElasticsearchRecord::Relation#where!` on nested, provided `:none` key
* [ref] minor code tweaks and comment updates

## [1.5.2] - 2023-07-12
* [fix] `ElasticsearchRecord::Relation#limit` setter method `limit_value=` to work with **delegate_query_nil_limit?**

## [1.5.1] - 2023-07-11
* [fix] `ElasticsearchRecord::ModelApi` 'drop!' & 'truncate!' methods to support correct parameter 'confirm'
* [ref] improved yard documentation

## [1.5.0] - 2023-07-10
* [add] additional `ElasticsearchRecord::ModelApi` methods **drop!** & **truncate!**, which have to be called with a `confirm:true` parameter
* [add] `ElasticsearchRecord::Base.delegate_query_nil_limit` to automatically delegate a relations `limit(nil)`-call to the **max_result_window** _(set to 10.000 as default)_
* [add] `ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements#access_shard_doc?` which checks, if the **PIT**-shard_doc order is available
* [add] support for **_shard_doc** as a default order for `ElasticsearchRecord::Relation#pit_results`
* [ref] `ElasticsearchRecord::Base.relay_id_attribute` to a more coherent name: `delegate_id_attribute` 
* [ref] `ElasticsearchRecord::Relation#ordered_relation` to optimize already ordered relations
* [ref] gemspecs to support different versions of Elasticsearch
* [ref] improved README
* [fix] `ElasticsearchRecord::Relation#pit_results` infinite loop _(caused by missing order)_
* [fix] `ElasticsearchRecord::Relation#pit_results` results generation without 'uniq' check of the array

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
