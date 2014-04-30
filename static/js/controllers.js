var asanbanApp = angular.module('asanbanApp', ['ngResource']);

//TODO: Move this into a separate file
asanbanApp.factory('Metrics', ['$resource',
  function($resource){
    return $resource('/metrics?aggregate_by=start_milestone&current_milestones_only=true&start_date=:start_date&end_date=:end_date', 
    	{}, {
      query: {method:'GET'}
    });
  }]);

asanbanApp.controller('AsanbanDashboardCtrl', ['$scope', 'Metrics',
  function($scope, Metrics) {
  	var format_date = function(date) {
  		return date.toISOString().substring(0, 10);
  	};

  	var start_date = new Date();
		start_date.setMonth(start_date.getMonth() - 2);
  	$scope.start_date = format_date(start_date);
  	$scope.end_date = format_date(new Date());

    $scope.query = function() {
	    $scope.metrics = Metrics.query({start_date: $scope.start_date, end_date: $scope.end_date});
    };

    $scope.query();
  }]);
