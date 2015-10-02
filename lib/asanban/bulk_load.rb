require "rubygems"
require "json"
require "net/https"
require "mongo"
require "time"
require "yaml"

module Asanban
  class BulkLoad
    def self.run(config = nil)
      unless config
        if !File.exists?('asana.yml')
          puts "Must specify configuration in asana.yml"
          exit(1)
        end
        config = YAML::load(File.open('asana.yml'))
      end
      # Set Mongo Logger level and output to file
      Mongo::Logger.logger       = ::Logger.new('mongo.log')
      Mongo::Logger.logger.level = ::Logger::INFO

      api_key = config['asana_api_key']
      workspace_id = config['asana_workspace_id']
      project_id = config['asana_project_id']
      mongodb_uri = config['mongodb_uri']
      mongodb_dbname = config['mongodb_dbname']

      if (ARGV.count < 1 || ARGV.count > 3)
        puts "Syntax is: bulkload {dir} {stage} [mode]"
        puts "{dir} points to the directory containing the configuration files"
        puts "{stage} is 'LOCAL' or 'PROD'"
        puts "[mode] can be 'tasks' (to create task data) or 'times' to create milestone and lead time data. Script will do both if not specified."
        exit(1)
      else
        if (File.directory?(ARGV[0]))
          Dir.chdir(ARGV[0])
        else
          puts "Invalid directory: #{ARGV[0]}"
          exit(1)
        end
        if (ARGV[1].downcase == "local")
          mongoClient = Mongo::Client.new(['localhost:27017'], :database => mongodb_dbname)
        elsif (ARGV[1].downcase == "prod")
          mongoClient = Mongo::Client.new(mongodb_uri, :database => mongodb_dbname)
        else
          puts "Invalid stage: #{ARGV[1]}"
          exit(1)
        end
        if (mode = ARGV[2]) && !['tasks', 'times'].include?(mode)
          puts "Invalid mode: #{mode}"
          exit(1)
        end
      end

      tasks_collection = mongoClient[:tasks]

      if (mode == 'tasks' || !mode)
        puts "Creating/Updating tasks..."
        uri = URI.parse("https://app.asana.com/api/1.0/projects/#{project_id}/tasks?opt_fields=id,name,assignee,assignee_status,created_at,completed,completed_at,due_on,followers,modified_at,name,notes,projects,parent")
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
          #old_tasks = tasks_collection.find({"projects.id" => project_id, "completed" => false}).to_a
          tasks_collection.find().update_many("$set" => {:old => true})
          startTime = Time.now
          tasks['data'].each_with_index do |task, i|
            uri = URI.parse("https://app.asana.com/api/1.0/tasks/#{task['id']}/stories")
            req = Net::HTTP::Get.new(uri.path, header)
            req.basic_auth(api_key, '')
            res = http.start { |http| http.request(req) }
            stories = JSON.parse(res.body)

            if task['errors']
              puts "Server returned an error retrieving stories: #{task['errors'][0]['message']}"
            else
             task["stories"] = stories['data']
            end

            task["old"] = false
            tasks_collection.find(:id => task['id']).update_one(task, {:upsert => true})
            puts "Created task: #{task['id']} for #{task['name']}"

            if (((i + 1) % 100) == 0)
              if (timeElapsed = (Time.now - startTime) < 60)
                puts "Sleeping for one minute to avoid Asana's rate limit of 100 requests per minute"
                sleep (60 - timeElapsed)
              else
                puts "Reached 100 requests, but took more than 1 minute, thus we can safely continue"
              end
              startTime = Time.now
            end
          end

          puts "Done creating/updating tasks."
        end
      end

      if (mode == 'times' || !mode)
        puts "Creating milestone and lead time data..."
        milestone_times_collection = mongoClient[:milestone_times]
        lead_times_collection = mongoClient[:lead_times]
        # TODO: filter - complete_time = null or completed_time - now <= 24hours
        tasks_collection.find().each do |task|
          stories = task[:stories] || []
          task_id = task[:_id]
          task_name = task[:name]
          #TODO: Write a test...
          task_completed = task[:completed]
          task_deleted = task[:old]
          stories.each do |story|
            # Matches story text to: moved from $1:section to $2:section ($3:project)
            # This effectively finds when tasks are moved between sections
            if (story[:text] =~ /moved from (.*) \(.+\) to (.*) \(.+\) \((.*)\)/)
              start_milestone = $1.strip
              end_milestone = $2.strip
              timestamp = Time.parse(story["created_at"])
              day = "#{timestamp.year}-#{timestamp.month}-#{timestamp.day}"
              month = "#{timestamp.year}-#{timestamp.month}"
              year = timestamp.year.to_s
              end_story_id = story["id"]
              # Matches story text to: moved into start_milestone, or moved from .. to start_milestone
              # This effectively finds when tasks have started in the starting section of the movement in the 'if' above
              # This is used to measure the time the story has spend in the starting section
              if (start_story = stories.find {|s| s['text'] =~ /moved .*to #{start_milestone}/})
                #TODO: Refactor to use record_time
                start_story_id = start_story["id"]
                start_timestamp = Time.parse(start_story["created_at"])
                elapsed_time_seconds = timestamp - start_timestamp
                elapsed_days = elapsed_time_seconds / (60.0 * 60.0 * 24.0)

                milestone = {"day" => day, "month" => month, "year" => year,
                  "task_id" => task_id, "task_name" => task_name, "date" => Time.parse(day),
                  "task_completed" => task_completed, "task_deleted" => task_deleted,
                  "start_milestone" => start_milestone, "end_milestone" => end_milestone,
                  "start_story_id" => start_story_id, "end_story_id" => end_story_id,
                  "elapsed_days" => elapsed_days}
                milestone_times_collection.find(:end_story_id => end_story_id).delete_one
                milestone_times_collection.insert_one(milestone)
                puts "Inserted milestone for task: #{task["name"]}, #{start_milestone} --> #{end_milestone}."
              else
                puts "Could not find time task entered #{start_milestone}"
              end
            end
          end

          # In all stories of this task, find the begin and end story matching with the milestones in the configuration
          if ((end_story = stories.find_all {|s| s['text'] =~ /moved .*to #{config['asana_ending_milestone']}/}[-1]) &&
              (start_story = stories.find_all {|s| s['text'] =~ /moved .*to #{config['asana_beginning_milestone']}/}[0]))
            lead_times_collection.find(:end_story_id => end_story["id"]).delete_one
            lead_time = record_time(task_id, task_completed, task_deleted, start_story, config['asana_beginning_milestone'], end_story, config['asana_ending_milestone'], lead_times_collection)
            puts "Inserted lead time for task: #{task["name"]}, spent #{lead_time["elapsed_days"]} days from #{config['asana_beginning_milestone']} --> #{config['asana_ending_milestone']}."
          end
        end
        puts "Finished creating milestone and lead time data."
      end
      puts "Done!"
    end

    #Visible For Testing
    def self.record_time(task_id, task_completed, task_deleted, start_story, start_milestone, end_story, end_milestone, collection)
      end_story_id = end_story["id"]
      start_story_id = start_story["id"]
      start_timestamp = Time.parse(start_story["created_at"])
      end_timestamp = Time.parse(end_story["created_at"])
      elapsed_time_seconds = end_timestamp - start_timestamp
      elapsed_days = elapsed_time_seconds / (60.0 * 60.0 * 24.0)
      day = "#{end_timestamp.year}-#{end_timestamp.month}-#{end_timestamp.day}"
      month = "#{end_timestamp.year}-#{end_timestamp.month}"
      year = end_timestamp.year.to_s

      record = {"day" => day, "month" => month, "year" => year,
        "task_id" => task_id, "date" => Time.parse(day),
        "task_completed" => task_completed, "task_deleted" => task_deleted,
        "start_milestone" => start_milestone, "end_milestone" => end_milestone,
        "start_story_id" => start_story_id, "end_story_id" => end_story_id,
        "elapsed_days" => elapsed_days}
      collection.find(:end_story_id => end_story_id).delete_one
      collection.insert_one(record)
      record
    end
  end
end
