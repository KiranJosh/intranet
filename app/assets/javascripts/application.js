// This is a manifest file that'll be compiled into application.js, which will include all the files
// listed below.
//
// Any JavaScript/Coffee file within this directory, lib/assets/javascripts, vendor/assets/javascripts,
// or vendor/assets/javascripts of plugins, if any, can be referenced here using a relative path.
//
// It's not advisable to add code directly here, but if you do, it'll appear at the bottom of the
// compiled file.
//
// Read Sprockets README (https://github.com/sstephenson/sprockets#sprockets-directives) for details
// about supported directives.
//
//= require jquery
//= require jquery.turbolinks
//= require jquery_ujs
//= require twitter/bootstrap
//= require turbolinks
//= require redactor-rails
//= require jquery-ui
//= require jquery-ui/sortable
//= require bootstrap-datepicker/core
//= require bootstrap-switch
//= require jquery_nested_form
//= require jqBootstrapValidation
//= require select2.min
//= require colorbox-rails
//= require jquery.timepicker.js
//= require twitter/typeahead
//= require jquery.validate.min.js
//= require light/users.js
//= require screamout/filter.js
//= require screamout/global.js
//= require redactor-rails
//= require_tree .

$(document).ready(function(){
$('.datepicker').datepicker({
  format: "dd-mm-yyyy",
  autoclose: true
})
})

$(document).ready(function(){
$('.new-datepicker').datepicker({
  format: "dd-mm-yyyy",
  autoclose: true
})
})

$(document).ready(function(){
  $("body").on("nested:fieldAdded", function() {
    $('.fields .new-datepicker').datepicker({
      format: "dd-mm-yyyy"
    })
  })
})

var readURL;
readURL = function(input, src_id) {
  var reader;
  if (input.files && input.files[0]) {
    reader = new FileReader;
    reader.onload = function(e) {
      $(src_id).attr('src', e.target.result);
    };
    reader.readAsDataURL(input.files[0]);
  }
};

var generate_code;
generate_code = function() {
  $.get('/projects/generate_code', function(response, status) {
    $('#project_code').val(response.code);
  });
};
