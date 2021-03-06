require 'sequel/no_core_ext' # to avoid sequel ~> 3.0 coliding with ActiveRecord
require 'multi_json'

module Dynflow
  module PersistenceAdapters

    Sequel.extension :migration

    class Sequel < Abstract
      include Algebrick::TypeCheck

      MAX_RETRIES = 10
      RETRY_DELAY = 1

      attr_reader :db

      def pagination?
        true
      end

      def filtering_by
        META_DATA.fetch :execution_plan
      end

      def ordering_by
        META_DATA.fetch :execution_plan
      end

      META_DATA = { execution_plan: %w(state result started_at ended_at real_time execution_time),
                    action:         %w(caller_execution_plan_id caller_action_id),
                    step:           %w(state started_at ended_at real_time execution_time action_id progress_done progress_weight) }

      def initialize(config)
        @db = initialize_db config
        migrate_db
      end

      def find_execution_plans(options = {})
        data_set = filter(order(paginate(table(:execution_plan), options), options), options[:filters])

        data_set.map do |record|
          HashWithIndifferentAccess.new(MultiJson.load(record[:data]))
        end
      end

      def delete_execution_plans(filters, batch_size = 1000)
        count = 0
        filter(table(:execution_plan), filters).each_slice(batch_size) do |plans|
          uuids = plans.map { |p| p.fetch(:uuid) }
          @db.transaction do
            table(:step).where(execution_plan_uuid: uuids).delete
            table(:action).where(execution_plan_uuid: uuids).delete
            count += table(:execution_plan).where(uuid: uuids).delete
          end
        end
        return count
      end

      def load_execution_plan(execution_plan_id)
        load :execution_plan, uuid: execution_plan_id
      end

      def save_execution_plan(execution_plan_id, value)
        save :execution_plan, { uuid: execution_plan_id }, value
      end

      def load_step(execution_plan_id, step_id)
        load :step, execution_plan_uuid: execution_plan_id, id: step_id
      end

      def save_step(execution_plan_id, step_id, value)
        save :step, { execution_plan_uuid: execution_plan_id, id: step_id }, value
      end

      def load_action(execution_plan_id, action_id)
        load :action, execution_plan_uuid: execution_plan_id, id: action_id
      end

      def save_action(execution_plan_id, action_id, value)
        save :action, { execution_plan_uuid: execution_plan_id, id: action_id }, value
      end

      def to_hash
        { execution_plans: table(:execution_plan).all.to_a,
          steps:           table(:step).all.to_a,
          actions:         table(:action).all.to_a }
      end

      private

      TABLES = { execution_plan: :dynflow_execution_plans,
                 action:         :dynflow_actions,
                 step:           :dynflow_steps }

      def table(which)
        db[TABLES.fetch(which)]
      end

      def initialize_db(db_path)
        ::Sequel.connect db_path
      end

      def self.migrations_path
        File.expand_path('../sequel_migrations', __FILE__)
      end

      def migrate_db
        ::Sequel::Migrator.run(db, self.class.migrations_path, table: 'dynflow_schema_info')
      end

      def save(what, condition, value)
        table           = table(what)
        existing_record = with_retry { table.first condition }

        if value
          value         = value.with_indifferent_access
          record        = existing_record || condition
          record[:data] = MultiJson.dump Type!(value, Hash)
          meta_data     = META_DATA.fetch(what).inject({}) { |h, k| h.update k.to_sym => value.fetch(k) }
          record.merge! meta_data
          record.each { |k, v| record[k] = v.to_s if v.is_a? Symbol }

          if existing_record
            with_retry { table.where(condition).update(record) }
          else
            with_retry { table.insert record }
          end

        else
          existing_record and with_retry { table.where(condition).delete }
        end
        value
      end

      def load(what, condition)
        table = table(what)
        if (record = with_retry { table.first(condition.symbolize_keys) } )
          HashWithIndifferentAccess.new MultiJson.load(record[:data])
        else
          raise KeyError, "searching: #{what} by: #{condition.inspect}"
        end
      end

      def paginate(data_set, options)
        page     = Integer(options[:page] || 0)
        per_page = Integer(options[:per_page] || 20)

        if page
          data_set.limit per_page, per_page * page
        else
          data_set
        end
      end

      def order(data_set, options)
        order_by = (options[:order_by] || :started_at).to_s
        unless META_DATA.fetch(:execution_plan).include? order_by
          raise ArgumentError, "unknown column #{order_by.inspect}"
        end
        order_by = order_by.to_sym
        data_set.order_by options[:desc] ? ::Sequel.desc(order_by) : order_by
      end

      def filter(data_set, filters)
        Type! filters, NilClass, Hash
        return data_set if filters.nil?
        unknown = filters.keys - META_DATA.fetch(:execution_plan) - %w[uuid caller_execution_plan_id caller_action_id]

        if filters.key?('caller_action_id') && !filters.key?('caller_execution_plan_id')
          raise ArgumentError, "caller_action_id given but caller_execution_plan_id missing"
        end

        if filters.key?('caller_execution_plan_id')
          data_set = data_set.join_table(:inner, TABLES[:action], :execution_plan_uuid => :uuid).
              select_all(TABLES[:execution_plan]).distinct
        end

        unless (unknown).empty?
          raise ArgumentError, "unkown columns: #{unknown.inspect}"
        end

        data_set.where filters.symbolize_keys
      end

      def with_retry
        attempts = 0
        begin
          yield
        rescue Exception => e
          attempts += 1
          log(:error, e)
          if attempts > MAX_RETRIES
            log(:error, "The number of MAX_RETRIES exceeded")
            raise Errors::PersistenceError.delegate(e)
          else
            log(:error, "Persistence retry no. #{attempts}")
            sleep RETRY_DELAY
            retry
          end
        end
      end
    end
  end
end
