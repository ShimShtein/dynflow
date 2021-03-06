module Dynflow
  module Executors
    class Parallel < Abstract
      class Pool < MicroActor
        class RoundRobin
          def initialize
            @data   = []
            @cursor = 0
          end

          def add(item)
            @data.push item
            self
          end

          def delete(item)
            @data.delete item
            self
          end

          def next
            @cursor = 0 if @cursor > @data.size-1
            @data[@cursor].tap { @cursor += 1 }
          end

          def empty?
            @data.empty?
          end
        end

        class JobStorage
          def initialize
            @round_robin = RoundRobin.new
            @jobs        = Hash.new { |h, k| h[k] = [] }
          end

          def add(work)
            @round_robin.add work.execution_plan_id unless tracked?(work)
            @jobs[work.execution_plan_id] << work
          end

          def pop
            return nil if empty?
            execution_plan_id = @round_robin.next
            @jobs[execution_plan_id].shift.tap { delete execution_plan_id if @jobs[execution_plan_id].empty? }
          end

          def empty?
            @jobs.empty?
          end

          private

          def tracked?(work)
            @jobs.has_key? work.execution_plan_id
          end

          def delete(execution_plan_id)
            @round_robin.delete execution_plan_id
            @jobs.delete execution_plan_id
          end
        end

        def initialize(core, pool_size, transaction_adapter)
          super(core.logger, core, pool_size, transaction_adapter)
        end

        private

        def delayed_initialize(core, pool_size, transaction_adapter)
          @core         = core
          @pool_size    = pool_size
          @free_workers = Array.new(pool_size) { Worker.new(self, transaction_adapter) }
          @jobs         = JobStorage.new
        end

        def on_message(message)
          match message,
                (on ~Work do |work|
                  @jobs.add work
                  distribute_jobs
                 end),
                (on WorkerDone.(~any, ~any) do |step, worker|
                  @core << PoolDone[step]
                  @free_workers << worker
                  distribute_jobs
                 end),
                (on Errors::PersistenceError do
                   @core << message
                 end)
        end

        def termination
          try_to_terminate
        end

        def try_to_terminate
          if terminating? && @free_workers.size == @pool_size
            @free_workers.map { |worker| worker.ask(Terminate) }.each(&:wait)
            @core << PoolTerminated
            terminate!
          end
        end

        def distribute_jobs
          try_to_terminate
          @free_workers.pop << @jobs.pop until @free_workers.empty? || @jobs.empty?
        end
      end
    end
  end
end
