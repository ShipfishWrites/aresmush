module AresMUSH
  module Jobs    
      
    def self.can_access_jobs?(actor)
      return false if !actor
      actor.has_permission?("access_jobs")
    end
    
    def self.categories
      JobCategory.all.map { |j| j.name }
    end
    
    def self.status_vals
      Global.read_config("jobs", "status").keys
    end
    
    def self.closed_jobs
      Job.all.select { |j| !j.is_open? }
    end
    
    def self.can_access_category?(actor, category)
      return true if actor.is_admin?
      return false if !Jobs.can_access_jobs?(actor)    
      actor.has_any_role?(category.roles)
    end

    def self.visible_replies(actor, job)
      if (Jobs.can_access_category?(actor, job.job_category))
        job.job_replies.to_a
      else
        job.job_replies.select { |r| !r.admin_only}
      end
    end
    
    def self.category_color(category)
      return "" if !category
      config = Global.read_config("jobs", "categories")
      key = config.keys.find { |k| k.downcase == category.downcase }
      reutrn "%xh" if !key
      return config[key]["color"]
    end
    
    def self.status_color(status)
      return "" if !status
      config = Global.read_config("jobs", "status")
      key = config.keys.find { |k| k.downcase == status.downcase }
      return "%xc" if !key
      return config[key]["color"]
    end
    
    def self.accessible_jobs(char, category_filter = nil)
      jobs = []
      if (category_filter)
        categories = JobCategory.all.select{ |j| category_filter.include?(j.name) && Jobs.can_access_category?(char, j) }
      else
        categories = JobCategory.all.select{ |j| Jobs.can_access_category?(char, j) }
      end
      
      categories.each do |j|
        jobs = jobs.concat(j.jobs.to_a)
      end
      jobs
    end
    
    def self.filtered_jobs(char, filter = nil)
      if (!filter)
        filter = char.jobs_filter
      end
            
      case filter
      when "ACTIVE"
        jobs = Jobs.accessible_jobs(char).select { |j| j.is_active? || j.is_unread?(char) }
      when "MINE"
        jobs = char.assigned_jobs.select { |j| j.is_open? }
      when "UNFINISHED"
        jobs = Jobs.accessible_jobs(char).select { |j| j.is_open? }
      when "UNREAD"
        jobs = char.unread_jobs
      when "ALL"
        jobs = Jobs.accessible_jobs(char)
      else # Category filter
        jobs = Jobs.accessible_jobs(char, [ filter ]).select { |j| j.is_active? || j.is_unread?(char) }
      end
        
      jobs.sort_by { |j| j.created_at }
    end
    
    def self.with_a_job(char, client, number, &block)
      job = Job[number]
      if (!job)
        client.emit_failure t('jobs.invalid_job_number')
        return
      end
      
      error = Jobs.check_job_access(char, job)
      if (error)
        client.emit_failure error
        return
      end
      
      yield job
    end
    
    def self.with_a_request(client, enactor, number, &block)
      job = Job[number]
      if (!job || job.author != enactor)
        client.emit_failure t('jobs.invalid_job_number')
        return
      end
      
      yield job
    end
    
    def self.comment(job, author, message, admin_only)
      JobReply.create(:author => author, 
        :job => job,
        :admin_only => admin_only,
        :message => message)
      if (admin_only)
        notification = t('jobs.discussed_job', :name => author.name, :number => job.id, :title => job.title)
        Jobs.notify(job, notification, author, false)
      else
        notification = t('jobs.responded_to_job', :name => author.name, :number => job.id, :title => job.title)
        Jobs.notify(job, notification, author)
      end
    end
    
    def self.can_access_job?(enactor, job)
      !Jobs.check_job_access(enactor, job)
    end
    
    def self.check_job_access(enactor, job, allow_author = false)
      if (allow_author)
        return nil if enactor == job.author
        return nil if job.participants.include?(enactor)
      end
      return t('dispatcher.not_allowed') if !Jobs.can_access_jobs?(enactor)
      return t('jobs.cant_access_category') if !Jobs.can_access_category?(enactor, job.job_category)
      return nil
    end
          
    def self.assign(job, assignee, enactor)
      job.update(assigned_to: assignee)
      job.update(status: "OPEN")
      notification = t('jobs.job_assigned', :number => job.id, :title => job.title, :assigner => enactor.name, :assignee => assignee.name)
      Jobs.notify(job, notification, enactor)
    end
    
    def self.open_requests(char)
      char.requests.select { |r| r.is_open? || r.is_unread?(char) }
    end
    
    def self.closed_status
      Global.read_config("jobs", "closed_status")
    end
        
    def self.notify(job, message, author, notify_submitter = true)
      Jobs.mark_unread(job)
      Jobs.mark_read(job, author)
      
      if (!notify_submitter)
        submitter = job.author
        if (submitter && !Jobs.can_access_category?(submitter, job.job_category))
          Jobs.mark_read(job, submitter)
        end
      end
      
      Global.client_monitor.emit_ooc(message) do |char|
        char && (Jobs.can_access_category?(char, job.job_category) || notify_submitter && char == job.author)
      end
            
      data = "#{job.id}|#{message}"
      Global.client_monitor.notify_web_clients(:job_update, data) do |char|
        char && (Jobs.can_access_category?(char, job.job_category) || notify_submitter && char == job.author)
      end
            
    end
    
    def self.reboot_required_notice
      File.exist?('/var/run/reboot-required') ? t('jobs.reboot_required') : nil
    end

    def self.change_job_title(enactor, job, title)
      job.update(title: title)
      notification = t('jobs.updated_job', :number => job.id, :title => job.title, :name => enactor.name)
      Jobs.notify(job, notification, enactor)
    end
        
    def self.change_job_category(enactor, job, category)
      job.update(category: category)
      notification = t('jobs.updated_job', :number => job.id, :title => job.title, :name => enactor.name)
      Jobs.notify(job, notification, enactor)
    end
    
    def self.check_filter_type(filter)
      types = ["ACTIVE", "MINE", "ALL", "UNFINISHED", "UNREAD"].concat(Jobs.categories)
      return t('jobs.invalid_filter_type', :names => types) if !types.include?(filter)
      return nil
    end
    
    def self.mark_read(job, char)      
      jobs = char.read_jobs || []
      jobs << job.id.to_s
      char.update(read_jobs: jobs)
    end
    
    def self.mark_unread(job)
      chars = Character.all.select { |c| !Jobs.is_unread?(job, c) }
      chars.each do |char|
        jobs = char.read_jobs || []
        jobs.delete job.id.to_s
        char.update(read_jobs: jobs)
      end
    end
    
    def self.is_unread?(job, char)
      !(char.read_jobs || []).include?(job.id.to_s)
    end
    
  end
end