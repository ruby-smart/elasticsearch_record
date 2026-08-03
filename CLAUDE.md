# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`elasticsearch_record` is a Ruby gem that implements an **ActiveRecord connection adapter for Elasticsearch**. It is not a wrapper around the Elasticsearch client — it plugs into ActiveRecord's real internals (Arel, connection adapters, schema statements, migrations) so that Elasticsearch indices behave like tables and models behave like `ActiveRecord::Base` descendants.

Ruby >= 2.7 (`.ruby-version` pins 3.2.5), `activerecord ~> 7.1`, `elasticsearch >= 7.17`.

## Commands

```bash
bin/setup                    # bundle install
bundle exec rake             # default task -> rspec
bundle exec rspec            # run the spec suite
bundle exec rspec spec/elasticsearch_record_spec.rb              # single file
bundle exec rspec spec/elasticsearch_record_spec.rb:12           # single example by line
bundle exec rspec --only-failures                                # uses .rspec_status persistence
bin/console                  # IRB with the gem loaded
bundle exec rake build       # build gem into pkg/ (bundler/gem_tasks)
bundle exec yard             # generate docs (see .yardopts)
```

**The spec suite is a placeholder.** `spec/` contains only `spec_helper.rb` and a stub spec whose second example (`expect(false).to eq(true)`) fails by design. There is no test infrastructure, no fixtures, and no live-cluster harness. Do not assume a green suite verifies a change — changes must be reasoned about against ActiveRecord/Arel internals, and behavioral verification requires a real Elasticsearch cluster.

## Branch layout

Branches map to Rails versions, and the gem is released per-branch:

- `main` / `rails-7-1-stable` — Rails 7.1 (gem 1.8+)
- `rails-7-0-stable` — Rails 7.0 (gem ≤ 1.7)
- `develop` — active development

Because the adapter overrides and reimplements private ActiveRecord internals, code is **tightly coupled to a specific Rails minor version**. Porting a fix across branches is usually a manual re-write, not a cherry-pick. `docs/CHANGELOG.md` carries parallel entry-sets per branch (some marked _"no gem release"_).

## Architecture

### The query pipeline

The central design: an ActiveRecord relation is compiled through Arel into an **`ElasticsearchRecord::Query` object** (not a SQL string), which is then dispatched to an `elasticsearch-api` endpoint.

```
Model.where(...)             ActiveRecord::Relation
  → relation extended with   ElasticsearchRecord::Relation::{QueryMethods,ValueMethods,...}
  → arel                     Arel AST + custom nodes (SelectQuery, SelectKind, SelectAgg, SelectConfigure)
  → Arel::Visitors::Elasticsearch#compile
  → claims sent to           Arel::Collectors::ElasticsearchQuery  (subclasses ElasticsearchRecord::Query)
  → ElasticsearchRecord::Query#query_arguments  (index / body / refresh / timeout / arguments)
  → ElasticsearchAdapter#api(gate, arguments)   → elasticsearch-api client
  → ElasticsearchRecord::Result
```

Key consequence: **`to_sql` returns a `Query` object, not a String.** Anything in ActiveRecord that assumes a SQL string will misbehave; `lib/active_record/connection_adapters/elasticsearch/database_statements.rb` documents which inherited methods are untouched, supported-but-unused, silently ignored, or made to raise.

### Visitor / collector protocol

`lib/arel/visitors/elasticsearch_base.rb` defines the mechanism the whole query builder rests on:

- **`claim(action, *args)`** — the only way the visitor talks to the collector. Actions: `:index`, `:type`, `:status`, `:columns`, `:arguments`, `:argument`, `:body`, `:assign`, `:refresh`, `:timeout`. Claims always return `nil` to prevent accidental assignment.
- **`assign(key, value, &block)`** — builds nested body hashes. Inside a block, `@nested` is set so sub-assignments accumulate into `@nested_args` and get merged into the parent value instead of claiming on the query. The merge rules (Hash-into-Hash, Array-append, `nil` deletes a key unless `:__force__`, `nil` key delegates to the value) live in that method and are relied on throughout `elasticsearch_query.rb`.
- `compile` **must reset** `@nested`/`@nested_args` on every call — a build-time exception would otherwise leak state into the next query (this was a real bug, fixed in 1.8.2).
- `method_missing` raises `UnsupportedVisitError` for any unhandled `visit_*` — so unsupported Arel nodes fail loudly rather than producing a wrong query. The fix for such a failure is to construct a custom Arel node, not to add SQL-ish handling.
- The special assign key **`:__query__`** escapes the body and re-dispatches as a claim — this is how `refresh`, `timeout`, and other query-level (non-body) settings are set from relation chain methods (`configure(:__query__, refresh: true)`).

Visitors are split by concern: `elasticsearch_query.rb` (searches/documents) and `elasticsearch_schema.rb` (index DDL), both mixed into `Arel::Visitors::Elasticsearch`.

### Query types and gates

`ElasticsearchRecord::Query` enumerates every operation as a `TYPE_*` constant and maps it to an API **gate** (`GATES`, e.g. `TYPE_INDEX_CREATE → 'indices.create'`; unmapped types call the core action directly). `READ_TYPES` drives `write?`, which the adapter uses for readonly-connection checks. A **failed** query (`status == STATUS_FAILED`) is not an error — it swaps in a `FAILED_BODIES` body that matches nothing, the equivalent of SQL `where('1=0')`. Note Elasticsearch has no index-update API: updates are decomposed into separate mapping/setting/alias types.

### Adapter

`ElasticsearchAdapter < AbstractAdapter` composes concerns from `lib/active_record/connection_adapters/elasticsearch/`: `Quoting`, `DatabaseStatements`, `SchemaStatements`, `TableStatements`, `Transactions`, `UnsupportedImplementation`.

- **`#api(gate, arguments, name)`** is the single execution point — it handles logging/instrumentation, `took` statistics, timeout detection, and exception translation (`Elastic::Transport` errors → `ActiveRecord::StatementInvalid`/`RecordNotUnique`/`StatementTimeout`/…).
- **`METADATA_FIELDS`** declares the virtual `_id`/`_index`/`_score`/`_type`/`_ignored` columns that no mapping returns. `_id` is the primary key.
- `TYPE_MAP` / `NATIVE_DATABASE_TYPES` map Elasticsearch mapping types to AR types, including ES-specific types in `elasticsearch/type/` (`Object`, `Nested`, `Range`, `FormatString`, `MulticastValue`).
- `UnsupportedImplementation#define_unsupported_method` generates methods that raise `NotImplementedError` — the idiom for AR APIs Elasticsearch cannot honor.
- **Transactions are not supported.** `supports_transactions?` is `false` and transactions are silently swallowed by default; `ElasticsearchRecord.error_on_transaction = true` makes them raise (breaks transactional tests).
- Config extras beyond standard AR: `table_name_prefix` / `table_name_suffix` (applied to index names), `log`, and `migrations_paths` defaulting to `db/migrate_elasticsearch`.

### Model side

`ElasticsearchRecord::Base` is abstract, includes `Core`, `ModelSchema`, `Persistence`, `Querying`, and hard-wires `connects_to database: { writing: :elasticsearch, reading: :elasticsearch }` — so the `database.yml` connection **must** be named `elasticsearch`. Points worth knowing before editing:

- `Core#relation` extends each new relation with `ElasticsearchRecord::Extensions::Relation` — this is how the ES-specific chain methods get onto relations without touching AR's delegate cache.
- `delegate_id_attribute` reconciles the ES `_id` primary key with a user-defined `id` field; `undelegate_id_attribute_with` temporarily disables it because much of Rails forces primary-key access through `#id`/`#id=`.
- `delegate_query_nil_limit` makes `.limit(nil)` mean `max_result_window` instead of ES's default size of 10.
- `Relation::CoreMethods` overrides `ordered_relation`/`reverse_sql_order` to check `access_id_fielddata?` — sorting on `_id` is disallowed by default cluster settings.
- `ModelApi` (`Model.api`) is the direct index-manipulation surface (`mappings`, `settings`, `bulk`, `insert`, `drop!(confirm: true)`, …), bypassing the relation pipeline.
- Relation results can bypass record instantiation entirely: `hits`, `results`, `aggregations`, `buckets`, `total`, `pit_results` (see `Relation::ResultMethods`).

### Patches

`lib/elasticsearch_record/patches/` monkey-patches ActiveRecord and Arel (`relation_merger`, `select_core`, `select_manager`, `select_statement`, `update_manager`, `update_statement`), loaded via `ActiveSupport.on_load(:active_record)` in `lib/elasticsearch_record.rb`. These are excluded from YARD docs. They are the most Rails-version-fragile part of the codebase — check them first when upgrading Rails.

## Conventions

- Most files carry `# frozen_string_literal: true` (the `active_record`/`arel` trees consistently; several files under `lib/elasticsearch_record/` do not) — match the file you are editing.
- Public methods carry YARD docs (`@param`/`@return`); RDoc-style `+method+` markup is used in prose. Docs are published to rubydoc.info, so keep them accurate.
- Overrides of ActiveRecord internals are commented with why the override exists and what upstream method it mirrors (`see @ ActiveRecord::...`). Preserve this — it is the only record of what needs re-checking on a Rails upgrade.
- Relation chain methods follow AR's pairing: `foo` spawns, `foo!` mutates in place.
- Changes get a `docs/CHANGELOG.md` entry tagged `[add]` / `[ref]` / `[fix]` under the target version.
