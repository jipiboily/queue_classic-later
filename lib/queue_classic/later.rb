require "json"

require "queue_classic"
require "queue_classic/later/version"

module QC
  module Later

    TABLE_NAME = "queue_classic_later_jobs"
    DEFAULT_COLUMNS = ["id", "q_name", "method", "args", "created_at", "not_before"]

    def format_custom(custom, message)
      values = custom.send(message).map do |v|
        v.nil? ? "NULL" : v
      end

      return ", #{values.join(', ')}" unless custom.empty?
      ''
    end

    module Setup
      extend self

      def create
        QC.default_conn_adapter.connection.transaction do
          QC.default_conn_adapter.execute("CREATE TABLE #{QC::Later::TABLE_NAME} (q_name varchar(255), method varchar(255), args text, not_before timestamptz)")
        end
      end

      def drop
        QC.default_conn_adapter.connection.transaction do
          QC.default_conn_adapter.execute("DROP TABLE IF EXISTS #{QC::Later::TABLE_NAME}")
        end
      end
    end

    module Queries
      extend self

      def insert(q_name, not_before, method, args, custom={})
        QC.log_yield(:action => "insert_later_job") do
          s = "INSERT INTO #{QC::Later::TABLE_NAME} (q_name, not_before, method, args) VALUES ($1, $2, $3, $4)"
          QC.default_conn_adapter.execute(s, q_name, not_before, method, JSON.dump(args))
        end
      end

      def delete_and_capture(not_before)
        s = "DELETE FROM #{QC::Later::TABLE_NAME} WHERE not_before <= $1 RETURNING *"
        # need to ensure we return an Array even if QC.default_conn_adapter.execute returns a single item
        [QC.default_conn_adapter.execute(s, not_before)].compact.flatten
      end
    end

    module QueueExtensions
      def enqueue_in(seconds, method, *args)
        enqueue_at(Time.now + seconds, method, *args)
      end

      def enqueue_at(not_before, method, *args)
        QC::Later::Queries.insert(name, not_before, method, args)
      end

      def enqueue_in_with_custom(seconds, method, custom, *args)
        QC::Later::Queries.insert(name, Time.now + seconds, method, args, custom)
      end
    end

    extend self
    def process_tick
      QC::Later::Queries.delete_and_capture(Time.now).each do |job|
        queue = QC::Queue.new(job["q_name"])

        custom_keys = job.keys - DEFAULT_COLUMNS
        if !custom_keys.empty?
          custom = custom_keys.each_with_object(Hash.new) {|k, hash| hash[k] = job[k] if job.has_key?(k) }

          QC.log_yield(:action => "insert_qc_job") do
            s = "INSERT INTO queue_classic_jobs (q_name, method, args#{QC::Later::format_custom(custom, :keys)}) VALUES ($1, $2, $3#{QC::Later::format_custom(custom, :values)})"
            QC.default_conn_adapter.execute(s, job["q_name"], job["method"], job['args'])
          end
        else
          queue.enqueue(job["method"], *JSON.parse(job["args"]))
        end
      end
    end

    # run QC::Later.tick as often as necessary via your clock process
    def tick skip_transaction=false
      if skip_transaction
        process_tick
      else
        QC.default_conn_adapter.connection.transaction do
          process_tick
        end
      end
    end
  end
end

QC::Queue.send :include, QC::Later::QueueExtensions
