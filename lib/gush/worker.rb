require 'sidekiq'
require 'yajl'

module Gush
  class Worker
    include ::Sidekiq::Worker
    sidekiq_options retry: false

    def perform(workflow_id, job_id, configuration_json)
      configure_client(configuration_json)

      workflow = client.find_workflow(workflow_id)
      job = workflow.find_job(job_id)

      start = Time.now
      report(workflow, job, :started, start)

      failed = false
      error = nil

      mark_as_started(workflow, job)
      begin
        job.work
      rescue Exception => e
        failed = true
        error = e
      end

      unless failed
        report(workflow, job, :finished, start)
        mark_as_finished(workflow, job)

        enqueue_outgoing_jobs(workflow.id, job)
      else
        mark_as_failed(workflow, job)
        report(workflow, job, :failed, start, error.message)
      end
    end

    private

    attr_reader :client

    def configure_client(config_json)
      @client = Client.new(Configuration.from_json(config_json))
    end

    def mark_as_finished(workflow, job)
      job.finish!
      client.persist_job(workflow.id, job)
    end

    def mark_as_failed(workflow, job)
      job.fail!
      client.persist_job(workflow.id, job)
    end

    def mark_as_started(workflow, job)
      job.start!
      client.persist_job(workflow.id, job)
    end

    def report_workflow_status(workflow, job)
      message = {workflow_id: workflow.id, status: workflow.status, started_at: workflow.started_at, finished_at: workflow.finished_at }
      client.workflow_report(message)
    end

    def report(workflow, job, status, start, error = nil)
      message = {status: status, workflow_id: workflow.id, job: job.name, duration: elapsed(start)}
      message[:error] = error if error
      client.worker_report(message)
    end

    def elapsed(start)
      (Time.now - start).to_f.round(3)
    end

    def enqueue_outgoing_jobs(workflow_id, job)
      job.outgoing.each do |job_name|
        out = client.load_job(workflow_id, job_name)
        if out.ready_to_start?
          client.enqueue_job(workflow_id, out)
        end
      end
    end
  end
end
