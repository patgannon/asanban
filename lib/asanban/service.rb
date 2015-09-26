require "rubygems"
require "json"
require "mongo"
require "sinatra"
require "yaml"
require "descriptive_statistics"

module Asanban
  class Service < Sinatra::Base
    set :public_folder, File.expand_path(File.join('..', '..', '..', 'static'), __FILE__)
    set :port, ENV['PORT'] if ENV['PORT'] #set by Heroku

    configure :production, :development do
      if !File.exists?('asana.yml')
        puts "Must specify configuration in asana.yml"
        exit(1)
      end
      set :config, YAML::load(File.open('asana.yml'))
    end
    # Set Mongo Logger level and output to file
    Mongo::Logger.logger       = ::Logger.new('mongo.log')
    Mongo::Logger.logger.level = ::Logger::INFO

    get '/metrics' do
      config = settings.config
      mongodb_uri = config['mongodb_uri']
      mongodb_dbname = config['mongodb_dbname']
      if (ARGV.count > 0)
        if (ARGV[0].downcase == "local")
          mongoClient = Mongo::Client.new(['localhost:27017'], :database => mongodb_dbname)
        elsif (ARGV[0].downcase == "prod")
          mongoClient = Mongo::Client.new(mongodb_uri, :database => mongodb_dbname)
        else
          puts "Invalid stage: #{ARGV[0]}"
          exit(1)
        end
      end
      aggregate_by = params[:aggregate_by]
      return [400, "Cannot aggregate by #{aggregate_by}"] unless ["year", "month", "day", "start_milestone"].include? aggregate_by
      content_type :json

      map_function = "function() { emit(this.#{aggregate_by}, { count: 1, elapsed_days: this.elapsed_days }); };"

      reduce_function = "function (name, values){
        var n = {count : 0, elapsed_days : 0};
        for ( var i=0; i<values.length; i++ ){
          n.count += values[i].count;
          n.elapsed_days += values[i].elapsed_days;
        }
        return n;
      };"

      finalize_function = "function(who, res){
        res.avg = res.elapsed_days / res.count;
        return res;
      };"

      map_reduce_options = {:finalize => finalize_function, :out => {inline: 1}}

      if (aggregate_by == "start_milestone")
          {result['_id'] => 
            {"count" => result["value"]["count"], 
        result = mongoClient[:milestone_times].find().map_reduce(map_function, reduce_function, map_reduce_options)
        hashes = result.each do |result|
              "cycle_time" => result["value"]["avg"]}}
        end
        #TODO: Refactor
        hash = {}
        hashes.map do |h|
          hash.merge! h
        end

        #TODO: Move this (and other M/Rs?) to bulk loader
        map_function = "function() { emit(this.task_id, {end_milestone: this.end_milestone, end_story_id: this.end_story_id, day: this.day}); };"
        reduce_function = "function (name, values){
          var n = {end_milestone : '', end_story_id : 0};
          for ( var i=0; i<values.length; i++ ){
            if (values[i].end_story_id > n.end_story_id) {
              n.end_milestone = values[i].end_milestone;
              n.end_story_id = values[i].end_story_id;
              n.day = values[i].day;
            }
          }
          return n;
        };"

        query = {"task_completed" => false, "task_deleted" => false}
        if ((start_date = params[:start_date]) && (end_date = params[:end_date]))
          query["date"] = {"$gte" => Time.parse(start_date), "$lte" => Time.parse(end_date)}
        end
        results = mongoClient[:milestone_times].find(query).map_reduce(map_function, reduce_function, {:out => {inline: 1}})
        elapsed_days_by_phase = {}
          task_id = result['_id']
          end_milestone = result["value"]["end_milestone"]
          if (end_milestone == "Dev Ready (10): Strat(5), Eng (1), Imp(3), Eme")
            puts "task_id: #{task_id}"
          end
          day = result["value"]["day"]
        results.each do |result|
          milestone_metrics = (hash[end_milestone] ||= {})
          milestone_metrics["current"] ||= 0
          milestone_metrics["current"] += 1
          elapsed_seconds = Time.now - Time.parse(day)
          elapsed_days = ((elapsed_seconds / 60) / 60) / 24
          milestone_metrics["current_days_total"] ||= 0
          milestone_metrics["current_days_total"] += elapsed_days
          elapsed_days_by_phase[end_milestone] ||= []
          elapsed_days_by_phase[end_milestone].push elapsed_days
        end

        hash.each do |key, value|
          if (value["current_days_total"] && value["current"])
            value["current_days_average"] = value["current_days_total"] / value["current"]
            all_elapsed_days = elapsed_days_by_phase[key]
            value["current_days_stdev"] = all_elapsed_days.standard_deviation
          end
        end

        if (params[:current_milestones_only])
          hash = hash.select {|phase, phase_metrics| phase_metrics["current_days_average"] }
        end
        return hash.to_json
      end

      if (milestone = params[:milestone])
        results = mongoClient[:milestone_times].find(:start_milestone => milestone).map_reduce(map_function, reduce_function, {:out => {inline: 1}})
      else
        results = mongoClient[:lead_times].find().map_reduce(map_function, reduce_function, {:finalize => finalize_function, :out => {inline: 1}})
      end
      sortedresults = results.sort do |a, b|
        datestring_to_int(a[:_id]) <=> datestring_to_int(b[:_id])
      end
      sortedresults.to_json
    end

    def datestring_to_int(datestring)
      datestring.split("-").map {|part| part.length == 1 ? "0" + part : part}.join("").to_i
    end
  end
end
