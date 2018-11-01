class TimeSheetsController < ApplicationController
  skip_before_filter :verify_authenticity_token
  load_and_authorize_resource only: [:index, :users_timesheet, :edit_timesheet, :update_timesheet, :new, :add_time_sheet]
  before_action :user_exists?, only: [:create, :daily_status]

  def new
    @from_date = params[:from_date]
    @to_date = params[:to_date]
    @user = User.find_by(id: params[:user_id]) if params[:user_id].present?
    @time_sheets = @user.time_sheets.build
  end

  def create
    return_value, time_sheets_data = @time_sheet.parse_timesheet_data(params) unless params['user_id'].nil?
    if return_value == true
      create_time_sheet(time_sheets_data, params)
    else
      render json: { text: '' }, status: :bad_request
    end
  end

  def index
    @from_date = params[:from_date] || Date.today.beginning_of_month.to_s
    @to_date = params[:to_date] || Date.today.to_s
    timesheets = TimeSheet.load_timesheet(@time_sheets.pluck(:id), @from_date.to_date, @to_date.to_date) if TimeSheet.from_date_less_than_to_date?(@from_date, @to_date)
    @timesheet_report = TimeSheet.generete_employee_timesheet_report(timesheets, @from_date.to_date, @to_date.to_date) if timesheets.present?
  end

  def users_timesheet
    unless current_ability.can? :users_timesheet, TimeSheet.where(user_id: params[:user_id]).first
      flash[:error] = "Invalid access"
      redirect_to time_sheets_path and return
    end
    @from_date = params[:from_date] || Date.today.beginning_of_month.to_s
    @to_date = params[:to_date] || Date.today.to_s
    @user = User.find(params[:user_id])
    @individual_timesheet_report, @total_work_and_leaves = TimeSheet.generate_individual_timesheet_report(@user, params) if TimeSheet.from_date_less_than_to_date?(@from_date, @to_date)
  end

  def edit_timesheet
    unless current_ability.can? :edit_timesheet, TimeSheet.where(user_id: params[:user_id]).first
      flash[:error] = "Invalid access"
      redirect_to users_time_sheets_path and return
    end

    @user = User.find_by(id: params[:user_id])
    @time_sheets = @user.time_sheets.where(date: params[:time_sheet_date].to_date)
    @time_sheet_date = params[:time_sheet_date]
  end

  def update_timesheet
    unless current_ability.can? :update_timesheet, TimeSheet.where(user_id: params[:user_id]).first
      flash[:error] = "Invalid access"
      redirect_to edit_time_sheets_path and return
    end

    @from_date = Date.today.beginning_of_month.to_s
    @to_date = Date.today.to_s
    @user = User.find_by(id: params['user_id'])
    @time_sheet_date = params[:time_sheet_date]
    @time_sheets = @user.time_sheets.where(date: params[:time_sheet_date].to_date)
    return_value = TimeSheet.update_time_sheet(timesheet_params)
    if return_value == true
      flash[:notice] = 'Timesheet Updated Succesfully'
      redirect_to users_time_sheets_path(@user.id, from_date: @from_date, to_date: @to_date)
    else
      error_message = TimeSheet.create_error_message_while_updating_time_sheet(return_value)
      flash[:error] = error_message
      render 'edit_timesheet'
    end
  end

  def add_time_sheet
    @from_date = params['user']['from_date']
    @to_date = params['user']['to_date']
    @user = User.find_by(id: params['user']['user_id'])
    return_value, error_messages, @time_sheets = TimeSheet.create_time_sheet(@user.id, timesheet_params)
    if return_value == true
      flash[:notice] = 'Timesheet created succesfully'
      redirect_to users_time_sheets_path(user_id: @user.id, from_date: @from_date, to_date: @to_date)
    else
      error_messages = TimeSheet.create_error_message_while_creating_time_sheet(error_messages)
      flash[:error] = error_messages.join("<br>").html_safe
      render 'new'
    end
  end

  def create_time_sheet(time_sheets_data, params)
    @time_sheet.attributes = time_sheets_data
    if @time_sheet.save
      render json: { text: "*Timesheet saved successfully!*" }, status: :created
    else
      error_message = 
        if @time_sheet.errors[:from_time].present? || @time_sheet.errors[:from_time].present?
          error =  @time_sheet.errors[:from_time] if @time_sheet.errors[:from_time].present?
          error = @time_sheet.errors[:to_time] if @time_sheet.errors[:to_time].present?
          error
        else
          TimeSheet.create_error_message_for_slack(@time_sheet.errors.full_messages)
        end
      SlackApiService.new.post_message_to_slack(params['channel_id'], error_message.join(' '))
      render json: { text: 'Fail' }, status: :unprocessable_entity
    end
  end

  def daily_status
    @time_sheet = TimeSheet.new
    time_sheet_log = TimeSheet.parse_daily_status_command(params)
    if time_sheet_log
      render json: { text: time_sheet_log }, status: :ok
    else
      render json: { text: 'Fail' }, status: :unprocessable_entity
    end
  end

  def projects_report
    @from_date = params[:from_date] || Date.today.beginning_of_month.to_s
    @to_date = params[:to_date] || Date.today.to_s
    @projects_report = TimeSheet.load_projects_report(@from_date.to_date, @to_date.to_date) if TimeSheet.from_date_less_than_to_date?(@from_date, @to_date)
    @projects_report_in_json, @project_without_timesheet = TimeSheet.create_projects_report_in_json_format(@projects_report, @from_date.to_date, @to_date.to_date)
  end

  def individual_project_report
    @from_date = params[:from_date]
    @to_date = params[:to_date]
    @project = Project.find(params[:id])
    @individual_project_report, @project_report = TimeSheet.generate_individual_project_report(@project, params) if TimeSheet.from_date_less_than_to_date?(@from_date, @to_date)
  end

  private

  def user_exists?
    load_user
    @time_sheet = TimeSheet.new
    @user = TimeSheet.fetch_email_and_associate_to_user(params['user_id']) if @user.blank?
    unless @user
      render json: { text: 'You are not part of organization contact to admin' }, status: :unauthorized
    end
  end

  def load_user
    @user = User.where('public_profile.slack_handle' => params['user_id']).first unless params['user_id'].nil?
  end
  
  def timesheet_params
    params.require(:user).permit(:time_sheets_attributes => [:project_id, :date, :from_time, :to_time, :description, :id ])
  end
end