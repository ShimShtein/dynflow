module Dynflow
  module PersistenceAdapters
    class Abstract

      # The logger is set by the world when used inside it
      attr_accessor :logger

      def register_world(world)
        @worlds ||= Set.new
        @worlds << world
      end

      def log(level, message)
        (@worlds.first && @worlds.first.logger).send(level, message)
      end

      def pagination?
        false
      end

      def filtering_by
        []
      end

      def ordering_by
        []
      end

      # @option options [Integer] page index of the page (starting at 0)
      # @option options [Integer] per_page the number of the items on page
      # @option options [Symbol] order_by name of the column to use for ordering
      # @option options [true, false] desc set to true if order should be descending
      # @option options [Hash{ String => Object,Array<object> }] filters hash represents
      #   set of allowed values for a given key representing column
      def find_execution_plans(options = {})
        raise NotImplementedError
      end

      # @param filters [Hash{ String => Object }] filters to determine
      #   what to delete
      # @param batch_size the size of the chunks to iterate over when
      #   performing the deletion
      def delete_execution_plans(filters, batch_size = 1000)
        raise NotImplementedError
      end

      def load_execution_plan(execution_plan_id)
        raise NotImplementedError
      end

      def save_execution_plan(execution_plan_id, value)
        raise NotImplementedError
      end

      def load_step(execution_plan_id, step_id)
        raise NotImplementedError
      end

      def save_step(execution_plan_id, step_id, value)
        raise NotImplementedError
      end

      def load_action(execution_plan_id, action_id)
        raise NotImplementedError
      end

      def save_action(execution_plan_id, action_id, value)
        raise NotImplementedError
      end

      # for debug purposes
      def to_hash
        raise NotImplementedError
      end
    end
  end
end
