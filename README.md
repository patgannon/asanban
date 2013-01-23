# Asanban

TODO: Add pointer to post on dev.bizo.com

## Installation and Usage

0. Make sure you have ruby 1.9 and rubygems installed and available on your system path.
1. Create a directory which will contain a configuration file with your API and DB settings.  You can call it "asana" or whatever you like.
2. Run: "gem install asanban" (or better yet, use bundler)
3. Install MongoDB on your local machine, if you haven't already.
4. Provision a production installation of MongoDB.  A free account at mongolab should get you started if needed.
5. Create a YAML file called asana.yml in the directory you created in step 1.  The file should have the following structure:

mongodb_uri: mongodb://[user]:[password]@[server]:[port]/[db-name]  (Note that this is for the production MongoDB installation)
mongodb_dbname: [db-name]  (for both environments)
asana_api_key: [your Asana API key - available in the Asana UI]
asana_workspace_id: [your Asana workspace ID]
asana_project_id: [the ID of the Asana project for which you would like to track metrics]
asana_beginning_milestone: [the name of the first stage in your Kanban system, eg. Dev Ready]
asana_ending_milestone: [the name of the last stage in your Kanban system, eg. Production]

6. Run: "asana-load local" (the bulk loader).  This will create task, milestone and lead time data in your local MongoDB, in the DB with the name given in the configuration file specified above.

Note: You must follow the Asana conventions outlined above for the bulk loader to work, particularly naming your priority headers as follows: "{STAGE NAME} ({WIP})" (parens must be specified around WIP limit).

7. If the process succeeded and the data created in your local MongoDB looks reasonable, you can go ahead and create the data in your production MongoDB instance by running: "asana-load prod"

8. Run: "asana-service".  This starts the web service that will serve up your aggregated lead time data.

9. You can hit http://localhost:4567/metrics?aggregate_by=month to see your data in JSON format.  (You can also pass in "year" or "day" instead of "month".)  There is also a very rough prototype of a page with a raphy-charts graph showing the data from the web service that you can hit by visiting http://localhost:4567/metrics.html .  This is just an example of how to consume the data; it needs a lot of work.

10. Since the web service is implemented with Sinatra, you will want to create a create a rack-up file if you're going to deploy it to production (or Heroku).  Do that by creating a file called config.ru in the directory you created in step 1, which contains the following:

load Gem.bin_path('asanban', 'asanban-service', '0.0.1')

11. Schedule the bulk loader in cron to run every night.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
