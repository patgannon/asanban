require "rubygems"
require "json"
require "mongo"
require "sinatra"
require "yaml"

module Asanban
	class Service < Sinatra::Base
		set :public_folder, File.expand_path(File.join('..', '..', '..', 'static'), __FILE__)
		set :port, ENV['PORT'] if ENV['PORT'] #set by Heroku

		if !File.exists?('asana.yml')
		  puts "Must specify configuration in asana.yml"
		  exit(1)
		end
		config = YAML::load(File.open('asana.yml'))

		get '/metrics' do
		  conn = Mongo::Connection.from_uri(config['mongodb_uri'])
		  db = conn.db(config["mongodb_dbname"])
			aggregate_by = params[:aggregate_by]
			return [400, "Cannot aggregate by #{aggregate_by}"] unless ["year", "month", "day"].include? aggregate_by

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

			map_reduce_options = {:finalize => finalize_function, :out => "mr_results"}
			if (milestone = params[:milestone])
				map_reduce_options[:query] = {"start_milestone" => milestone}
				collection = db["milestone_times"]
			else
				collection = db["lead_times"]
			end

			results = collection.map_reduce(map_function, reduce_function, map_reduce_options)
			
			content_type :json
			results.find().map do |result|
				[result['_id'], result["value"]["avg"]]
			end.sort {|a, b| datestring_to_int(a[0]) <=> datestring_to_int(b[0])}.to_json
		end

		def datestring_to_int(datestring)
			datestring.split("-").map {|part| part.length == 1 ? "0" + part : part}.join("").to_i
		end
	end

	puts "Running asanban web service"
	Service.run!
end
