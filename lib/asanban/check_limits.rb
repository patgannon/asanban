require "rubygems"
require "json"
require "net/https"
require "net/smtp"
require "yaml"
require "gmail_xoauth"
require "time"

module Asanban
  class CheckLimits
    def self.run(config = nil)
      if (ARGV.count != 1)
        puts "Syntax is: checklimits {dir}"
        puts "{dir} points to the directory containing the configuration files"
        exit(1)
      else
        if (File.directory?(ARGV[0]))
          Dir.chdir(ARGV[0])
        else
          puts "Invalid directory: #{ARGV[0]}"
          exit(1)
        end
      end

      unless config
        if !File.exists?('asana2.yml')
          puts "Must specify Asana configuration in asana2.yml"
          exit(1)
        end
        config = YAML::load(File.open('asana2.yml'))
      end
      if !File.exists?('asana3.yml')
        puts "Must specify Asana configuration in asana3.yml"
        exit(1)
      end
      sectionsOverLimit = YAML::load(File.open('asana3.yml'))

      api_key = config['asana_api_key']
      workspace_id = config['asana_workspace_id']
      projects = config['asana_project_id']

      projects.each do |project|
        project_name = project[0]
        project_id = project[1]['id']
        if (!sectionsOverLimit.has_key?(project_name)) #Check if project present in config file, otherwise create
          sectionsOverLimit[project_name] = Hash.new
        end
        puts "Retrieving tasks for project: #{project_name}"
        uri = URI.parse("https://app.asana.com/api/1.0/projects/#{project_id}/tasks?opt_fields=id,name,assignee.name,created_at,tags.name,completed")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        header = { "Content-Type" => "application/json" }
        path = "#{uri.path}?#{uri.query}"
        req = Net::HTTP::Get.new(path, header)
        req.basic_auth(api_key, '')
        res = http.start { |http| http.request(req) }
        tasks = JSON.parse(res.body)

        if tasks['errors']
          puts "Server returned an error retrieving tasks: #{tasks['errors'][0]['message']}"
        else
          tasksInSection = Array.new
          expediteTasksInSection = Array.new
          sectionName = ""
          tooManyTasks = false
          tooManyExpedites = false
          sectionLimit = 1000 # Initialize with 1000 to capture newly added tasks without section
          expediteLimit = 1 # For now, fixed limit on Expedites
          tasks['data'].each do |task|
            if (task['name'] =~ /(.*) \((.*)\):/) #Scan for sections
              if (tooManyTasks) # Check if the previous section had too many tasks
                case sectionsOverLimit[project_name][sectionName]
                when "Active"
                  puts "NOTE: more tasks than limit allows. Check if overflow on next iteration as well."
                  sectionsOverLimit[project_name][sectionName] = "OverLimit"
                when "OverLimit"
                  puts "NOTE: more tasks than limit allows. Sending e-mail."
                  sectionsOverLimit[project_name][sectionName] = "Critical"
                  latestTask = self.findLastItemAdded(tasksInSection, sectionName, header, api_key, http)
                  message = self.getLimitMessage(latestTask, project, sectionName, sectionLimit, tasksInSection, tooManyExpedites)
                  # TODO: Extend by also posting Asana conversation
                  self.sendMail(message)
                when "Critical"
                  puts "NOTE: Section still over the limit. Not resending email."
                else
                  puts "Unknown section status"
                end
              else
                if (sectionsOverLimit[project_name][sectionName] == "Critical")
                  puts "NOTE: Section restored. Sending email."
                  message = self.getRestoredMessage(project, sectionName, sectionLimit, tasksInSection)
                  self.sendMail(message)
                end
                sectionsOverLimit[project_name][sectionName] = "Active"
              end
              tooManyTasks = false
              tasksInSection.clear
              expediteTasksInSection.clear
              sectionName = $1
              if (!sectionsOverLimit[project_name].has_key?(sectionName))
                sectionsOverLimit[project_name][sectionName] = "Active"
              end
              sectionLimit = eval($2)
              if (!sectionLimit)
                sectionLimit = 1000 # Should be enough
              end
              puts "Section: #{sectionName} with limit: #{sectionLimit.to_s}"
            else
              tasksInSection.push(task)
              # Check if task has a tag EXPEDITE and is not completed yet
              if (!task['tags'].find_all {|t| t['name'] == "EXPEDITE"}.empty? && !task['completed'])
                expediteTasksInSection.push(task)
              end
              if (((tasksInSection.count - expediteTasksInSection.count) > sectionLimit) \
                || (expediteTasksInSection.count > expediteLimit))
                tooManyTasks = true
                if (expediteTasksInSection.count > expediteLimit)
                  tooManyExpedites = true
                end
                # TODO: extend with checking tags of tasks with specific section Limits (e.g. 8 research, but only 2 PhD)
                # TODO: check on the number of tasks per assignee and filter on those limits as well.
                # TODO: separate status (Active/OverLimit/Critical) with expedite status
                # TODO: print expedite when expedite overflow and tasks if task overflow
              end
            end
          end
        end
        File.open('asana3.yml', 'w') {|f| f.write sectionsOverLimit.to_yaml }
      end
      puts "Finished checking Limits."
    end

    def self.findLastItemAdded(fTasksInSection, fSectionName, fHeader, fApiKey, fHTTP)
      latestTimeStamp = Time.at(0)
      latestTask = ""
      fTasksInSection.each do |task|
        uri = URI.parse("https://app.asana.com/api/1.0/tasks/#{task['id']}/stories")
        req = Net::HTTP::Get.new(uri.path, fHeader)
        req.basic_auth(fApiKey, '')
        res = fHTTP.start { |http| http.request(req) }
        stories = JSON.parse(res.body)

        if task['errors']
          puts "Server returned an error retrieving stories: #{task['errors'][0]['message']}"
        end
        end_story = stories['data'].find_all {|s| s['text'] =~ /moved .*to #{fSectionName}/}[-1]
        if (!end_story)
          # Story started in this section. Get task creation date
          timestamp = Time.parse(task["created_at"])
        else
          timestamp = Time.parse(end_story["created_at"])
        end
        if (timestamp > latestTimeStamp)
          latestTimeStamp = timestamp
          latestTask = task
        end
      end
      return latestTask
    end

    def self.getLimitMessage(fLatestTask, fProject, fSection, fSectionLimit, fAllTasks, fIsExpediteExceeded)
      assigneeName = ""
      if (fLatestTask['assignee'])
        assigneeName = fLatestTask['assignee']['name']
      else
        assigneeName = "Not assigned"
      end

      project_name = fProject[0]
      project_receiver = fProject[1]['receiver']
      project_mail = fProject[1]['mail']

      alltaskformat = ""
      fAllTasks.each_with_index do |task, index|
        alltaskformat += "#{index+1}) #{task['name']}"
        if (task['assignee'])
          alltaskformat += ", #{task['assignee']['name']} \n"
        else
          alltaskformat += ", Not assigned\n"
        end
      end
      taskOrExpedite = "task"
      if (fIsExpediteExceeded)
        taskOrExpedite = "expedite"
      end
      msgstr  = "To: #{project_receiver} <#{project_mail}>" + "\n"
      msgstr += "Subject: Exceeding section #{taskOrExpedite} limit!" + "\n"
      msgstr += "" + "\n"
      msgstr += "You have exceeded the section #{taskOrExpedite} limit!" + "\n"
      msgstr += "Project: #{project_name}" + "\n"
      msgstr += "Section: #{fSection}" + "\n"
      msgstr += "Limit: #{fSectionLimit}" + "\n"
      msgstr += "" + "\n"
      msgstr += "Latest task entered: #{fLatestTask['name']}" + "\n"
      msgstr += "Assigned: #{assigneeName}" + "\n"
      msgstr += "" + "\n"
      msgstr += "All tasks in section #{fSection}:" + "\n"
      msgstr += "#{alltaskformat}"
      return msgstr
    end

    def self.getRestoredMessage(fProject, fSection, fSectionLimit, fAllTasks)
      project_name = fProject[0]
      project_receiver = fProject[1]['receiver']
      project_mail = fProject[1]['mail']

      alltaskformat = ""
      fAllTasks.each_with_index do |task, index|
        alltaskformat += "#{index+1}) #{task['name']}"
        if (task['assignee'])
          alltaskformat += ", #{task['assignee']['name']} \n"
        else
          alltaskformat += ", Not assigned\n"
        end
      end
      msgstr  = "To: #{project_receiver} <#{project_mail}>" + "\n"
      msgstr += "Subject: Section limit restored" + "\n"
      msgstr += "" + "\n"
      msgstr += "The section limit has been restored." + "\n"
      msgstr += "Project: #{project_name}" + "\n"
      msgstr += "Section: #{fSection}" + "\n"
      msgstr += "Limit: #{fSectionLimit}" + "\n"
      msgstr += "" + "\n"
      msgstr += "All tasks in section #{fSection}:" + "\n"
      msgstr += "#{alltaskformat}"
      return msgstr
    end

    def self.sendMail(fMessage)
      if !File.exists?('mail.yml')
        puts "Must specify Mail configuration in mail.yml"
        exit(1)
      end
      configMail = YAML::load(File.open('mail.yml'))

      smtp = Net::SMTP.new('smtp.gmail.com', 587)
      smtp.enable_starttls_auto
      begin
        smtp.start('gmail.com', configMail['user'], configMail['access_token'], :xoauth2)
      rescue
        # Authorization with access token failed, refresh token and retry
        result = `python oauth2.py --client_id=#{configMail['client_id']} --client_secret=#{configMail['client_secret']} --refresh_token=#{configMail['refresh_token']}`
        configMail['access_token'] = ""
        # Filter new access token and write to disk for future use
        if (result =~ /Access Token: (.*)\nAccess Token Expiration Seconds*/)
          configMail['access_token'] = $1
          File.open('mail.yml', 'w') {|f| f.write configMail.to_yaml }
        else
          throw "Error extracting access token from oauth2.py script."
        end
        smtp.start('gmail.com', configMail['user'], configMail['access_token'], :xoauth2)
      end

      smtp.send_message fMessage, configMail['user'], configMail['user']
      smtp.finish
    end
  end
end
