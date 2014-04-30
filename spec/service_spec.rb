ENV['RACK_ENV'] = 'test'
require 'asanban'
require 'rspec'
require 'rack/test'

describe Asanban::Service do
  include Rack::Test::Methods

  before do
    config = { "mongodb_uri" => "mongodb://localhost/", "mongodb_dbname" => "asana_test" }
    app.settings.set(:config, config)
    conn = Mongo::Connection.from_uri(config['mongodb_uri'])
    db = conn.db(config["mongodb_dbname"])
    @milestone_times_collection = db["milestone_times"]
    @milestone_times_collection.drop
    @lead_times_collection = db["lead_times"]
    @lead_times_collection.drop
    @story_id_counter = 1

    class Time
      @stub_time = Time.parse("2013-9-30")
      def self.now()
        @stub_time
      end
    end
  end

  it "returns average lead times by year" do
    record_lead_time('Foo', "October 2, 2012", "October 14, 2012") #12 days
    record_lead_time('Bar', "May 12, 2013", "May 14, 2013") #2 days
    record_lead_time('Baz', "October 12, 2013", "October 16, 2013") #4 days

    get '/metrics', :aggregate_by => 'year'
    #Average: 12 days 2012, 3 days 2013
    expect(last_response.body).to eq('[["2012",12.0],["2013",3.0]]')
  end

  it "returns average lead times by month" do
    record_lead_time('Foo', "September 20, 2013", "September 30, 2013") #10 days
    record_lead_time('Bar', "October 2, 2013", "October 14, 2013") #12 days
    record_lead_time('Baz', "October 12, 2013", "October 16, 2013") #4 days

    get '/metrics', :aggregate_by => 'month'
    #Average: 10 days September, 8 days in October
    expect(last_response.body).to eq('[["2013-9",10.0],["2013-10",8.0]]')
  end

  it "returns average lead times by day" do
    record_lead_time('Foo', "October 2, 2013", "October 14, 2013") #12 days
    record_lead_time('Bar', "October 12, 2013", "October 14, 2013") #2 days
    record_lead_time('Baz', "October 12, 2013", "October 16, 2013") #4 days

    get '/metrics', :aggregate_by => 'day'
    #Average: 7 days 10/14, 4 days 10/16
    expect(last_response.body).to eq('[["2013-10-14",7.0],["2013-10-16",4.0]]')
  end

  describe "milestone times recorded" do
    before do
      record_time('Foo', false, false, "September 1, 2013", "September 3, 2013", 'Dev Ready', 'Dev In Progress', @milestone_times_collection) #2
      record_time('Foo', false, false, "September 3, 2013", "September 10, 2013", 'Dev In Progress', 'Dev Done', @milestone_times_collection) #7
      record_time('Foo', false, false, "September 10, 2013", "September 15, 2013", 'Dev Done', 'PM Test, in Dev', @milestone_times_collection) #5
      record_time('Bar', false, false, "September 1, 2013", "September 7, 2013", 'Dev Ready', 'Dev In Progress', @milestone_times_collection) #6
      record_time('Bar', false, false, "September 7, 2013", "September 12, 2013", 'Dev In Progress', 'Dev Done', @milestone_times_collection) #5
      record_time('Bar', false, false, "September 12, 2013", "September 15, 2013", 'Dev Done', 'PM Test, in Dev', @milestone_times_collection) #3
    end

    it "returns average time in 'Dev Ready' by month" do
      get '/metrics', :aggregate_by => 'month', :milestone => 'Dev Ready'
      expect(last_response.body).to eq('[["2013-9",4.0]]')
    end

    it "returns average time in 'Dev In Progress' by month" do
      get '/metrics', :aggregate_by => 'month', :milestone => 'Dev In Progress'
      expect(last_response.body).to eq('[["2013-9",6.0]]')
    end

    describe "cycle times" do
      it "returns number of items currently in each phase" do
        get '/metrics', :aggregate_by => 'start_milestone'

        json = JSON(last_response.body)
        expect(json["PM Test, in Dev"]["current"]).to eq(2.0)
      end

      it "filters out tasks that are completed" do
        record_time('Baz', true, false, "September 1, 2013", "September 8, 2013", 'Dev Ready', 'Dev In Progress', @milestone_times_collection)
        record_time('Baz', true, false, "September 8, 2013", "September 14, 2013", 'Dev In Progress', 'Dev Done', @milestone_times_collection)
        record_time('Baz', true, false, "September 14, 2013", "September 19, 2013", 'Dev Done', 'PM Test, in Dev', @milestone_times_collection)

        get '/metrics', :aggregate_by => 'start_milestone'

        json = JSON(last_response.body)
        expect(json["PM Test, in Dev"]["current"]).to eq(2.0)
      end

      it "filters out deleted tasks" do
        record_time('Baz', false, true, "September 1, 2013", "September 8, 2013", 'Dev Ready', 'Dev In Progress', @milestone_times_collection)
        record_time('Baz', false, true, "September 8, 2013", "September 14, 2013", 'Dev In Progress', 'Dev Done', @milestone_times_collection)
        record_time('Baz', false, true, "September 14, 2013", "September 19, 2013", 'Dev Done', 'PM Test, in Dev', @milestone_times_collection)

        get '/metrics', :aggregate_by => 'start_milestone'

        json = JSON(last_response.body)
        expect(json["PM Test, in Dev"]["current"]).to eq(2.0)
      end

      it "returns time in phase for items still in phase" do
        record_time('Baz', false, false, "September 1, 2013", "September 8, 2013", 'Dev Ready', 'Dev In Progress', @milestone_times_collection)
        record_time('Baz', false, false, "September 8, 2013", "September 14, 2013", 'Dev In Progress', 'Dev Done', @milestone_times_collection)
        record_time('Baz', false, false, "September 14, 2013", "September 19, 2013", 'Dev Done', 'PM Test, in Dev', @milestone_times_collection)

        get '/metrics', :aggregate_by => 'start_milestone'

        json = JSON(last_response.body)
        json["PM Test, in Dev"]["current_days_average"].should be_within(0.01).of(13.66)
      end

      it "returns standard deviation of time in phase for items still in phase" do
        record_time('Baz', false, false, "September 1, 2013", "September 8, 2013", 'Dev Ready', 'Dev In Progress', @milestone_times_collection)
        record_time('Baz', false, false, "September 8, 2013", "September 14, 2013", 'Dev In Progress', 'Dev Done', @milestone_times_collection)
        record_time('Baz', false, false, "September 14, 2013", "September 19, 2013", 'Dev Done', 'PM Test, in Dev', @milestone_times_collection)

        get '/metrics', :aggregate_by => 'start_milestone'

        json = JSON(last_response.body)
        json["PM Test, in Dev"]["current_days_stdev"].should be_within(0.01).of(1.88)
      end

      it "filters out phases with no current items" do
        get '/metrics', :aggregate_by => 'start_milestone', :current_milestones_only => true
        json = JSON(last_response.body)
        json["Dev Ready"].should be_nil
      end

      it "returns number of items that flowed through each phase" do
        get '/metrics', :aggregate_by => 'start_milestone'
        json = JSON(last_response.body)
        expect(json["Dev Ready"]["count"]).to eq(2.0)
      end

      it "returns cycle time for each phase" do
        get '/metrics', :aggregate_by => 'start_milestone'

        json = JSON(last_response.body)
        expect(json["Dev Ready"]["cycle_time"]).to eq(4.0)
      end

      it "filters by start and end date" do
        record_time('Baz', false, false, "September 1, 2013", "September 8, 2013", 'Dev Ready', 'Dev In Progress', @milestone_times_collection)
        record_time('Baz', false, false, "September 8, 2013", "September 14, 2013", 'Dev In Progress', 'Dev Done', @milestone_times_collection)
        record_time('Baz', false, false, "September 14, 2013", "September 19, 2013", 'Dev Done', 'PM Test, in Dev', @milestone_times_collection)

        get '/metrics', :aggregate_by => 'start_milestone', :start_date => '2013-9-12', :end_date => '2013-9-17'

        json = JSON(last_response.body)
        expect(json["PM Test, in Dev"]["current"]).to eq(2.0)
        #TODO: check cycle time
      end
    end
  end

  it "returns an error when an invalid aggregation is specified" do
    get '/metrics', :aggregate_by => 'engineer'
    expect(last_response.status).to eq(400)
  end

  def app
    Asanban::Service
  end

  def record_lead_time(task_id, started_at, ended_at)
    record_time(task_id, false, false, started_at, ended_at, 'Dev Ready', 'Production', @lead_times_collection)
  end

  def record_time(task_id, completed, deleted, started_at, ended_at, start_milestone, end_milestone, collection)
    start_story = {'id' => @story_id_counter, 'created_at' => started_at}
    @story_id_counter += 1
    end_story = {'id' => @story_id_counter, 'created_at' => ended_at}
    Asanban::BulkLoad.record_time(task_id, completed, deleted, start_story, start_milestone, end_story, end_milestone, collection)
  end
end
