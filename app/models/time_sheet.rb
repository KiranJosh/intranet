class TimeSheet
  include Mongoid::Document
  include Mongoid::Timestamps
  extend CheckUser

  field :user_id
  field :project_id
  field :date,            :type => Date
  field :from_time,       :type => Time
  field :to_time,         :type => Time
  field :description,     :type => String

  belongs_to :user
  belongs_to :project

  validates :from_time, :to_time, uniqueness: { scope: [:user_id, :date], message: "\`Error :: Record already present\`" }
  validates :project_id, :date, :from_time, :to_time, :description, presence: true

  before_validation :check_vadation_while_creating_or_updateing_timesheet
  before_validation :date_less_than_two_days, on: :update

  MAX_TIMESHEET_COMMAND_LENGTH = 5
  DATE_FORMAT_LENGTH = 3
  MAX_DAILY_STATUS_COMMAND_LENGTH = 2
  ALLOCATED_HOURS = 8
  DAYS_FOR_UPDATE = 2

  def parse_timesheet_data(params)
    split_text = params['text'].split

    return false unless valid_command_format?(split_text, params['channel_id'])
    return false unless valid_project_name?(split_text[0], params)
    return false unless valid_date_format?(split_text[1], params)
    return false unless time_validation(split_text[1], split_text[2], split_text[3], params)

    time_sheets_data = time_sheets(split_text, params)
    return true, time_sheets_data
  end

  def valid_command_format?(split_text, channel_id)
    if split_text.length < MAX_TIMESHEET_COMMAND_LENGTH
      text = "\`Error :: Invalid timesheet format. Format should be <project_name> <date> <from_time> <to_time> <description>\`"
      SlackApiService.new.post_message_to_slack(channel_id, text)
      return false
    end
    return true
  end

  def valid_project_name?(project_name, params)
    user = User.where("public_profile.slack_handle" => params['user_id'])
    project = user.first.projects.find_by(display_name: /^#{project_name}$/i) rescue nil
    return true if !project.nil? || project_name == 'other'
    text = "\`Error :: You are not working on this project. Use /projects command to view your project\`"
    SlackApiService.new.post_message_to_slack(params['channel_id'], text)
    return false
  end

  def valid_date_format?(date, params)
    split_date = date.include?('/')? date.split('/') : date.split('-')
    
    if split_date.length < DATE_FORMAT_LENGTH
      text = "\`Error :: Invalid date format. Format should be dd/mm/yyyy\`"
      SlackApiService.new.post_message_to_slack(params['channel_id'], text)
      return false
    end

    valid_date?(split_date, date, params)
  end

  def valid_date?(split_date, date, params)
    valid_date = Date.valid_date?(split_date[2].to_i, split_date[1].to_i, split_date[0].to_i)
    unless valid_date
      SlackApiService.new.post_message_to_slack(params['channel_id'], "\`Error :: Invalid date\`")
      return false
    end
    return false unless date_less_than_seven_days(date, params) unless params['command'] == '/daily_status'
    return true if params['command'] == '/daily_status'
    return true
  end
  
  def check_vadation_while_creating_or_updateing_timesheet
    return false unless check_date_range
    return false unless from_time_greater_than_to_time?(from_time, to_time)
    return false unless timesheet_greater_than_current_time?
    return true
  end

  def timesheet_date_greater_than_assign_project_date
    user = User.find(user_id)
    user_project = UserProject.find_by(user_id: user.id, project_id: project_id, end_date: nil)
      if date < user_project.start_date
        return true
      end
    return false
  end

  def date_less_than_seven_days(date, params)
    if date < 7.days.ago
      text = "\`Error :: Not allowed to fill timesheet for this date. If you want to fill the timesheet, meet your manager.\`"
      errors.add(:date, text)
      SlackApiService.new.post_message_to_slack(params['channel_id'], text)
      return false
    end
    return true
  end

  def date_less_than_two_days
    if date < Date.today - DAYS_FOR_UPDATE
      text = "Error :: Not allowed to edit timesheet for this date. You can edit timesheet for past 2 days."
      errors.add(:date, text)
      return false
    end
    return true
  end

  def check_date_range
    if date > Date.today
      text = "Error :: Can't fill the timesheet for future date."
      errors.add(:date, text)
      return false
    elsif timesheet_date_greater_than_assign_project_date
      text = "Error :: Not allowed to fill timesheet for this date. As you were not assigned on project for this date"
      errors.add(:date, text)
    end
    return true
  end

  def timesheet_greater_than_current_time?
    text = "Error :: Can't fill the timesheet for future time."
    if from_time >= Time.now
      errors.add(:from_time, text)
      return false
    elsif to_time > Time.now
      errors.add(:to_time, text)
      return false      
    end
    return true
  end

  def from_time_greater_than_to_time?(from_time, to_time)
    if from_time >= to_time
       text = "\`Error :: From time must be less than to time\`"
       errors.add(:from_time, text)
       return false
     end
     return true
  end

  def time_validation(date, from_time, to_time, params)
    from_time = valid_time?(date, from_time, params, :from_time)
    return false unless from_time
    to_time = valid_time?(date, to_time, params, :to_time)
    return false unless to_time
    return true
  end
  
  def valid_time?(date, time, params, attribute)
    time_format = check_time_format(time)

    if time_format
      return_value = Time.parse(date + ' ' + time_format) rescue nil
    end

    unless return_value
      text = "\`Error :: Invalid time format. Format should be HH:MM\`"
      errors.add(attribute, text) if params == 'from_ui'
      SlackApiService.new.post_message_to_slack(params['channel_id'], text) unless params == 'from_ui'
      return false
    end
    return_value
  end

  def check_time_format(time)
    return false if time.to_s.include?('.')
    return time + (':00') unless time.to_s.include?(':')
    time
  end

  def concat_description(split_text)
    description = ''
    split_text[4..-1].each do |string|
      description = description + string + ' '
    end
    description
  end

  def time_sheets(split_text, params)
    time_sheets_data = {}
    user = User.where("public_profile.slack_handle" => params['user_id'])
    project = load_project(user, split_text[0])
    time_sheets_data['user_id'] = user.first.id
    time_sheets_data['project_id'] = project.nil? ? nil : project.id
    time_sheets_data['date'] = Date.parse(split_text[1])
    time_sheets_data['from_time'] = Time.parse(split_text[1] + ' ' + split_text[2])
    time_sheets_data['to_time'] = Time.parse(split_text[1] + ' ' + split_text[3])
    time_sheets_data['description'] = concat_description(split_text)
    time_sheets_data
  end

  def self.parse_daily_status_command(params)
    split_text = params['text'].split
    if split_text.length < MAX_DAILY_STATUS_COMMAND_LENGTH
      time_sheet_log = get_time_sheet_log(params, params['text'])
    else
      text = "\`Error :: Invalid command options. Use /daily_status <date> to view your timesheet log\`"
      SlackApiService.new.post_message_to_slack(params['channel_id'], text)
    end
    time_sheet_log.present? ? time_sheet_log : false
  end

  def self.get_time_sheet_log(params, date)
    text = 'You have not filled timesheet for'
    text = date.present? ? "\`#{text} #{date}.\`" : "\`#{text} today.\`"
    if date.present?
      return false unless TimeSheet.new.valid_date_format?(date, params)
    end
    user = load_user(params['user_id'])
    time_sheets, time_sheet_message =
    date.present? ? load_time_sheets(user, Date.parse(date)) : load_time_sheets(user, Date.today.to_s)
    return false unless time_sheet_present?(time_sheets, params, text)
    time_sheet_log = prepend_index(time_sheets)
    time_sheet_message + ". Details are as follow\n\n" + time_sheet_log
  end

  def self.time_sheet_present?(time_sheets, params, text)
    unless time_sheets.present?
      SlackApiService.new.post_message_to_slack(params['channel_id'], text)
      return false
    end
    return true
  end

  def self.prepend_index(time_sheets)
    time_sheet_log = time_sheets.each_with_index.map{|time_sheet, index| time_sheet.join(' ').prepend("#{index + 1}. ") + " \n"}
    time_sheet_log.join('')
  end

  def self.search_user_and_send_reminder(users)
    users.each do |user|
      last_filled_time_sheet_date = user.time_sheets.order(date: :asc).last.date + 1 if time_sheet_present_for_reminder?(user)
      next if last_filled_time_sheet_date.nil?
      date_difference = calculate_date_difference(last_filled_time_sheet_date)
      if date_difference < 2 && last_filled_time_sheet_date < Date.today
        next if HolidayList.is_holiday?(last_filled_time_sheet_date)
        unless user_on_leave?(user, last_filled_time_sheet_date)
          unfilled_timesheet = last_filled_time_sheet_date unless time_sheet_filled?(user, last_filled_time_sheet_date)
        end
      else
        while(last_filled_time_sheet_date < Date.today)
          next last_filled_time_sheet_date += 1 if HolidayList.is_holiday?(last_filled_time_sheet_date)
          unless user_on_leave?(user, last_filled_time_sheet_date)
            unfilled_timesheet = last_filled_time_sheet_date unless time_sheet_filled?(user, last_filled_time_sheet_date)
            break
          end
          last_filled_time_sheet_date += 1
        end
      end
      unfilled_timesheet_present?(user, unfilled_timesheet)
    end
  end

  def self.load_time_sheets(user, date)
    time_sheet_log = []
    total_minutes = 0
    time_sheet_message = 'You worked on'
    user.first.worked_on_projects(date, date).includes(:time_sheets).each do |project|
      project.time_sheets.where(user_id: user.first.id, date: date).each do |time_sheet|
        time_sheet_data = []
        from_time = time_sheet.from_time.strftime("%I:%M%p")
        to_time = time_sheet.to_time.strftime("%I:%M%p")
        time_sheet_data.push(project.name, from_time, to_time, time_sheet.description)
        time_sheet_log << time_sheet_data
        minutes = calculate_working_minutes(time_sheet)
        total_minutes += minutes
        time_sheet_data = []
      end
      hours, minitues = calculate_hours_and_minutes(total_minutes.to_i)
      next if hours == 0 && minitues == 0
      time_sheet_message += " *#{project.name}: #{hours}H #{minitues}M*"
      total_minutes = 0
    end
    return time_sheet_log, time_sheet_message
  end

  def self.generete_employee_timesheet_report(timesheets, from_date, to_date)
    timesheet_reports = []
    timesheets.each do |timesheet|
      user = load_user_with_id(timesheet['_id'])
      users_timesheet_data              = {}
      users_timesheet_data['user_name'] = user.name
      users_timesheet_data['user_id']   = user.id
      project_details = []
      total_work      = 0
      timesheet['working_status'].each do |working_status|
        project_info = {}
        project_info['project_name'] = get_project_name(working_status['project_id'])
        worked_hours = convert_milliseconds_to_hours(working_status['total_time'])
        project_info['worked_hours'] = convert_hours_to_days(worked_hours)
        total_work += working_status['total_time']
        project_details << project_info
        users_timesheet_data['project_details'] = project_details
      end
      total_worked_hours = convert_milliseconds_to_hours(total_work)
      users_timesheet_data['total_worked_hours'] = convert_hours_to_days(total_worked_hours)
      users_timesheet_data['leaves'] = approved_leaves_count(user, from_date, to_date)
      timesheet_reports << users_timesheet_data
    end
    sort_on_user_name_and_project_name(timesheet_reports)
  end

  def self.create_projects_report_in_json_format(projects_report, from_date, to_date)
    projects_report_in_json = []
    project_names = []
    projects_report.each do |project_report|
      project_details = {}
      project = load_project_with_id(project_report['_id']['project_id'])
      project_names << project.name
      project_details['project_id'] = project.id
      project_details['project_name'] = project.name
      project_details['no_of_employee'] = project.get_user_projects_from_project(from_date, to_date).count
      total_hours = convert_milliseconds_to_hours(project_report['totalSum'])
      project_details['total_hours'] = convert_hours_to_days(total_hours)
      project_details['allocated_hours'] = get_allocated_hours(project, from_date, to_date)
      project_details['leaves'] = get_leaves(project, from_date, to_date)
      projects_report_in_json << project_details
      project_details = {}
    end
    projects_report_in_json.sort!{|previous_record, next_record| previous_record['project_name'] <=> next_record['project_name']}
    project_without_timesheet = get_project_without_timesheet(project_names, from_date, to_date) if project_names.present?
    return projects_report_in_json, project_without_timesheet
  end

  def self.generate_individual_timesheet_report(user, params)
    time_sheet_log = []
    individual_time_sheet_data = {}
    total_minutes = 0
    total_minutes_worked_on_projects = 0
    user.worked_on_projects(params[:from_date], params[:to_date]).includes(:time_sheets).each do |project|
      project.time_sheets.where(user_id: user.id, date: {"$gte" => params[:from_date], "$lte" => params[:to_date]}).order_by(date: :asc).each do |time_sheet|
        time_sheet_data = []
        from_time, to_time = format_time(time_sheet)
        working_minutes    = calculate_working_minutes(time_sheet)
        hours, minutes     = calculate_hours_and_minutes(working_minutes.to_i)
        time_sheet_record  = create_time_sheet_record(time_sheet, from_time, to_time, "#{hours}:#{minutes}")
        time_sheet_data    << time_sheet_record
        time_sheet_log     << time_sheet_data
        total_minutes      += working_minutes
        total_minutes_worked_on_projects += working_minutes
        time_sheet_data = []
      end
      working_details = {}
      total_worked_hours = convert_hours_to_days(total_worked_in_hours(total_minutes.to_i))
      working_details['daily_status'] = time_sheet_log
      working_details['total_worked_hours'] = total_worked_hours
      individual_time_sheet_data["#{project.name}"] = working_details
      time_sheet_log  = []
      working_details = {}
      total_minutes   = 0
    end
    total_work_and_leaves = get_total_work_and_leaves(user, params, total_minutes_worked_on_projects.to_i)
    return individual_time_sheet_data, total_work_and_leaves
  end


  def self.generate_individual_project_report(project, params)
    individual_project_report = {}
    total_minutes = 0
    total_minutes_worked_on_projects = 0
    project.get_user_projects_from_project(params[:from_date], params[:to_date]).includes(:time_sheets).each do |user|
      report_details = {}
      time_sheet_log = []
      user.time_sheets.where(project_id: project.id, date: {"$gte" => params[:from_date], "$lte" => params[:to_date]}).order_by(date: :asc).each do |time_sheet|
        working_minutes = calculate_working_minutes(time_sheet)
        total_minutes += working_minutes
        total_minutes_worked_on_projects += working_minutes
      end
      user_projects = user.get_user_projects_from_user(project.id, params[:from_date].to_date, params[:to_date].to_date)
      allocated_hours = total_allocated_hours(user_projects, params[:from_date].to_date, params[:to_date].to_date)
      leaves_count = total_leaves_count(user, user_projects, params[:from_date].to_date, params[:to_date].to_date)
      report_details['total_work'] = convert_hours_to_days(total_worked_in_hours(total_minutes.to_i))
      report_details['allocated_hours'] = convert_hours_to_days(allocated_hours)
      report_details['leaves'] = leaves_count
      time_sheet_log << report_details
      individual_project_report["#{user.name}"] = time_sheet_log
      total_minutes = 0      
    end
    project_report = get_total_work_and_leaves_for_project_report(project, params, total_minutes_worked_on_projects)
    return individual_project_report, project_report
  end

  def self.get_project_and_generate_weekly_report(mananers, from_date, to_date)
    mananers.each do |manager|
      unfilled_time_sheet_report = []
      weekly_report = []
      manager.managed_projects.each do |project|
        total_minutes = 0
        project.get_user_projects_from_project(from_date, to_date).includes(:time_sheets).each do |user|
          time_sheet_log = []
          minutes, users_without_timesheet = get_time_sheet_and_calculate_total_minutes(user, project, from_date, to_date)
          total_minutes += minutes
          unfilled_time_sheet_report << users_without_timesheet if users_without_timesheet.present?
          user_projects = user.get_user_projects_from_user(project.id, from_date.to_date, to_date.to_date)
          total_days_work = convert_hours_to_days(total_worked_in_hours(total_minutes.to_i))
          leaves_count = total_leaves_count(user, user_projects, from_date, to_date)
          holidays_count = get_holiday_count(from_date, to_date)
          if total_minutes != 0
            time_sheet_log.push(user.name, project.name, total_days_work, leaves_count, holidays_count) 
            weekly_report << time_sheet_log
          end
          total_minutes = 0
        end
      end
      send_report_through_mail(weekly_report, manager.email, unfilled_time_sheet_report) if weekly_report.present?
    end
  end

  def self.get_time_sheet_and_calculate_total_minutes(user, project, from_date, to_date)
    users_without_timesheet = []
    total_minutes = 0
    user_projects = user.get_user_projects_from_user(project.id, from_date.to_date, to_date.to_date)
    leaves_count = total_leaves_count(user, user_projects, from_date, to_date)
    time_sheets = get_time_sheet_between_range(user, project.id, from_date, to_date)
    if !time_sheets.present? && !project.timesheet_mandatory == false && 
       (user.role == ROLE[:employee] || user.role == ROLE[:intern])
         users_without_timesheet.push(user.name, project.name, leaves_count)
    end
    time_sheets.each do |time_sheet|
      working_minutes = calculate_working_minutes(time_sheet)
      total_minutes += working_minutes
    end
    return total_minutes, users_without_timesheet
  end

  def self.create_time_sheet_record(time_sheet, from_time, to_time, total_worked)
    time_sheet_record = {}
    time_sheet_record['id'] = time_sheet.id
    time_sheet_record['date'] = time_sheet.date
    time_sheet_record['from_time'] = from_time
    time_sheet_record['to_time'] = to_time
    time_sheet_record['total_worked'] = total_worked
    time_sheet_record['description'] = time_sheet.description
    time_sheet_record
  end

  def self.format_time(time_sheet)
    from_time = time_sheet.from_time.strftime("%I:%M%p")
    to_time = time_sheet.to_time.strftime("%I:%M%p")

    return from_time, to_time
  end

  def self.get_total_work_and_leaves_for_project_report(project, params, total_minutes_worked_on_projects)
    project_report = {}
    total_hours_worked_on_project = convert_hours_to_days(total_worked_in_hours(total_minutes_worked_on_projects.to_i))
    total_allocated_hours_on_projects = get_allocated_hours(project, params[:from_date].to_date, params[:to_date].to_date)
    total_leaves = get_leaves(project, params[:from_date].to_date, params[:to_date].to_date)
    project_report['total_worked_hours'] = total_hours_worked_on_project
    project_report['total_allocated_hourse'] = total_allocated_hours_on_projects
    project_report['total_leaves'] = total_leaves
    project_report
  end

  def self.get_total_work_and_leaves(user, params, total_minutes_worked_on_projects)
    total_work_and_leaves = {}
    total_worked_hours = total_worked_in_hours(total_minutes_worked_on_projects.to_i)
    total_work_and_leaves['total_work'] = convert_hours_to_days(total_worked_hours)
    total_work_and_leaves['leaves'] = approved_leaves_count(user, params[:from_date], params[:to_date])
    total_work_and_leaves
  end

  def self.send_report_through_mail(weekly_report, email, unfilled_time_sheet_report)
    csv = generate_weekly_report_in_csv_format(weekly_report)
    WeeklyTimesheetReportMailer.send_weekly_timesheet_report(csv, email, unfilled_time_sheet_report).deliver!
  end

  def self.calculate_working_minutes(time_sheet)
    TimeDifference.between(time_sheet.to_time, time_sheet.from_time).in_minutes
  end

  def self.get_allocated_hours(project, from_date, to_date)
    total_allocated_hours = 0
    project.get_user_projects_from_project(from_date, to_date).each do |user|
      user_projects = user.get_user_projects_from_user(project.id, from_date, to_date)
      allocated_hours = total_allocated_hours(user_projects, from_date, to_date)
      total_allocated_hours += allocated_hours
    end
    convert_hours_to_days(total_allocated_hours)
  end

  def self.get_working_days(from_date, to_date)
    working_days = from_date.business_days_until(to_date)
    no_of_holiday = get_holiday_count(from_date, to_date)
    working_days -= no_of_holiday
  end

  def self.get_leaves(project, from_date, to_date)
    total_leaves_count = 0
    project.get_user_projects_from_project(from_date, to_date).each do |user|
      user_projects = user.get_user_projects_from_user(project.id, from_date, to_date)
      leaves_count = total_leaves_count(user, user_projects, from_date, to_date)
      total_leaves_count += leaves_count
    end
    total_leaves_count
  end

  def self.total_allocated_hours(user_projects, from_date, to_date)
    total_allocated_hours = 0
    user_projects.each do |user_project|
      working_days =
        if user_project.end_date.present?
          if from_date <= user_project.start_date
            get_working_days(user_project.start_date, user_project.end_date)
          elsif from_date > user_project.start_date
            get_working_days(from_date, user_project.end_date)
          end
        else
          if from_date <= user_project.start_date
            get_working_days(user_project.start_date, to_date)
          elsif from_date > user_project.start_date
            get_working_days(from_date, to_date)
          end
        end
      allocated_hours = working_days * ALLOCATED_HOURS
      total_allocated_hours += allocated_hours
    end
    total_allocated_hours
  end
  
  def self.total_leaves_count(user, user_projects, from_date, to_date)
    total_leaves_count = 0
    user_projects.each do |user_project|
      leaves_count =
        if user_project.end_date.present?
          if from_date <= user_project.start_date
            approved_leaves_count(user, user_project.start_date, user_project.end_date)
          elsif from_date > user_project.start_date
            approved_leaves_count(user, from_date, user_project.end_date)
          end
        else
          if from_date <= user_project.start_date
            approved_leaves_count(user, user_project.start_date, to_date)
          elsif from_date > user_project.start_date
            approved_leaves_count(user, from_date, to_date)
          end
        end
      total_leaves_count += leaves_count
    end
    total_leaves_count
  end

  def self.generate_weekly_report_in_csv_format(weekly_report)
    headers = ['Employee name', 'Project name', 'No of days worked', 'Leaves', 'Holidays']
    weekly_report_in_csv = 
      CSV.generate(headers: true) do |csv|
        csv << headers
        weekly_report.each do |report|
          csv << report
        end
      end
    weekly_report_in_csv
  end

  def self.sort_on_user_name_and_project_name(timesheet_reports)
    sort_on_user_name = 
      timesheet_reports.sort{|previous_record, next_record| previous_record['user_name'] <=> next_record['user_name']}

    sort_on_project_name =
      sort_on_user_name.each do |report|
        report['project_details'].sort!{|previous_record, next_record| previous_record['project_name'] <=> next_record['project_name']}
      end

    sort_on_project_name
  end

  def self.unfilled_time_sheet_for_last_week(user)
    users_without_timesheet = []
    users_without_timesheet << user.name unless users_without_timesheet.include?(user.name)
    users_without_timesheet
  end

  def self.calculate_hours_and_minutes(total_minutes)
    hours, minutes = conver_minutes_into_hours(total_minutes)
    minutes = '%02i'%minutes
    return hours, minutes
  end

  def self.conver_minutes_into_hours(total_minutes)
    hours = total_minutes / 60
    minutes = total_minutes % 60
    return hours, minutes
  end

  def self.total_worked_in_hours(total_minutes)
    hours, minutes = conver_minutes_into_hours(total_minutes)
    hours = minutes < 30 ? hours : hours + 1
    hours
  end

  def self.convert_milliseconds_to_hours(milliseconds)
    hours = milliseconds / (1000 * 60 * 60)
    minutes = milliseconds / (1000 * 60) % 60
    hours = minutes < 30 ? hours : hours + 1
    hours
  end

  def self.convert_hours_to_days(total_allocated_hourse)
    days = hours = 0
    days = total_allocated_hourse / ALLOCATED_HOURS
    hours = total_allocated_hourse % ALLOCATED_HOURS
    result = hours > 0 ? "#{days} Days #{hours}H (#{total_allocated_hourse}H)" : "#{days} Days (#{total_allocated_hourse}H)"
    result
  end

  def self.get_project_without_timesheet(project_names, from_date, to_date)
    unfilled_timesheet_projects = []
    projects = Project.not_in(name: project_names)
    projects.where("$or" => [{end_date: nil}, {end_date: {"$gte" => from_date, "$lte" => to_date}}]).each do |project|
      project_detail = {}
      project_detail['project_id'] = project.id
      project_detail['project_name'] = project.name
      unfilled_timesheet_projects << project_detail
    end
    unfilled_timesheet_projects.sort{|previous_record, next_record| previous_record['project_name'] <=> next_record['project_name']}
  end

  def self.get_holiday_count(from_date, to_date)
    HolidayList.where(holiday_date: {"$gte" => from_date, "$lte" => to_date}).count
  end
  
  def self.time_sheet_present_for_reminder?(user)
    unless user.time_sheets.present?
      slack_uuid = user.public_profile.slack_handle
      message = "You haven't filled the timesheet for yesterday. Go ahead and fill it now. You can fill timesheet for past 7 days. If it exceeds 7 days then contact your manager."
      text_for_slack = "*#{message}*"
      text_for_email = "#{message}"
      TimesheetRemainderMailer.send_timesheet_reminder_mail(user, slack_uuid, text_for_email).deliver!
      send_reminder(slack_uuid, text_for_slack) unless slack_uuid.blank?
      return false
    end
    return true
  end

  def self.user_on_leave?(user, date)
    return false unless user.leave_applications.present?
    leave_applications = user.leave_applications.where(:start_at.gte => date)
    leave_applications.each do |leave_application|
      return true if date.between?(leave_application.start_at, leave_application.end_at)
    end
    return false
  end

  def self.time_sheet_filled?(user, date)
    filled_time_sheet_dates = user.time_sheets.pluck(:date)
    return false unless filled_time_sheet_dates.include?(date)
    return true
  end

  def self.unfilled_timesheet_present?(user, unfilled_timesheet)
    if unfilled_timesheet.present?
      slack_handle = user.public_profile.slack_handle
      message1 = "You haven't filled the timesheet from"
      message2 = "Go ahead and fill it now. You can fill timesheet for past 7 days. If it exceeds 7 days then contact your manager."
      text_for_slack = "*#{message1} #{unfilled_timesheet.to_date}. #{message2}*"
      text_for_email = "#{message1} #{unfilled_timesheet.to_date}. #{message2}"
      TimesheetRemainderMailer.send_timesheet_reminder_mail(user, slack_handle, text_for_email).deliver!
      send_reminder(slack_handle, text_for_slack) unless slack_handle.blank?
      return true
    end
    return false
  end

  def self.update_time_sheet(params)
    return_value = ''
    params['time_sheets_attributes'].each do |key, value|
      time_sheet = TimeSheet.find(value[:id])
      value['from_time'] = value['date'] + ' ' + value['from_time']
      value['to_time'] = value['date'] + ' ' + value['to_time'] 
      time_sheet.time_validation(value['date'], value['from_time'], value['to_time'], 'from_ui')
      return time_sheet.errors.full_messages.join(', ') if time_sheet.errors.full_messages.present?
      if time_sheet.update_attributes(value)
        return_value =  true
      else
        if time_sheet.errors[:from_time].present? || time_sheet.errors[:from_time].present?
          return time_sheet.errors[:from_time].join(', ') if time_sheet.errors[:from_time].present?
          return time_sheet.errors[:to_time].join(', ') if time_sheet.errors[:to_time].present?
        else
          return time_sheet.errors.full_messages.join(', ')
        end
      end
    end
    return_value
  end

  def self.get_errors_message(user, time_sheet_date)
    user.time_sheets.where(date: time_sheet_date.to_date).each do |time_sheet|
      return time_sheet.errors.full_messages if time_sheet.errors.full_messages.present?
    end
  end

  def self.calculate_date_difference(last_filled_time_sheet_date)
    TimeDifference.between(DateTime.current, DateTime.parse(last_filled_time_sheet_date.to_s)).in_days.round
  end

  def self.send_reminder(user_id, text)
    resp = JSON.parse(SlackApiService.new.open_direct_message_channel(user_id))
    SlackApiService.new.post_message_to_slack(resp['channel']['id'], text)
    SlackApiService.new.close_direct_message_channel(resp['channel']['id'])
    sleep 1
  end

  def load_project(user, display_name)
    user.first.projects.where(display_name: /^#{display_name}$/i).first
  end

  def self.create_error_message_for_slack(errors)
    errors.map do |error|
      index = error.index(/Error/)
      index = error.index(/Record/) if index.nil?
      error[index..-1].prepend("`").concat("`")
    end
  end

  def self.create_error_message(error)
    index = error.remove!("`").index(/Error/)
    error = error[index..-1] unless index.nil?
    error
  end

  def self.load_user(user_id)
    User.where("public_profile.slack_handle" => user_id)
  end

  def self.fetch_email_and_associate_to_user(user_id)
    call_slack_api_service_and_fetch_email(user_id)
  end

  def self.approved_leaves_count(user, from_date, to_date)
    leaves_count = 0
    leave_applications = user.leave_applications.where(
      "$and" => [{start_at: {"$gte" => from_date, "$lte" => to_date}}, 
                {leave_status: LEAVE_STATUS[1]}]
    )
    leave_applications.sum(:number_of_days)  
  end

  def self.get_time_sheet_between_range(user, project_id, from_date, to_date)
    user.time_sheets.where(project_id: project_id, date: {"$gte" => from_date, "$lte" => to_date}).order_by(date: :asc)
  end

  def self.get_project_name(project_id)
    Project.find_by(id: project_id).name
  end

  def self.get_time_sheet_of_date(user, date)
    user.time_sheets.where(date: date.to_date)
  end

  def self.from_date_less_than_to_date?(from_date, to_date)
    from_date.to_date <= to_date.to_date
  end

  def self.load_user_with_id(user_id)
    User.find_by(id: user_id)
  end
  
  def self.load_project_with_id(project_id)
    Project.find_by(id: project_id)
  end

  def self.load_timesheet(timesheet_ids, from_date, to_date)
    TimeSheet.collection.aggregate(
      [
        {
          "$match" => {
            "date" => {
              "$gte" => from_date,
              "$lte" => to_date
            },
            "_id" => {
              "$in" => timesheet_ids
            }
          }
        },
        {
          "$group" => {
            "_id" => {
              "user_id" => "$user_id",
              "project_id" => "$project_id"
            },
            "totalSum" => {
              "$sum" => {
                "$subtract" => [
                  "$to_time",
                  "$from_time"
                ]
              }
            }
          }
        },
        {
          "$group" => {
            "_id" => "$_id.user_id",
            "working_status" => {
              "$push" => {
                "project_id" => "$_id.project_id",
                "total_time" => "$totalSum"
              }
            }
          }
        }
      ]
    )
  end

  def self.load_projects_report(from_date, to_date)
    TimeSheet.collection.aggregate([
      {
        "$match"=>{
          "date"=>{
            "$gte"=> from_date,
            "$lte"=> to_date
          }
        }
      },
      {
        "$group"=>{
          "_id"=>{
            "project_id"=>"$project_id"
          },
          "totalSum"=>{
            "$sum"=>{
              "$subtract"=>[
                "$to_time",
                "$from_time"
              ]
            }
          }
        }
      }
    ])
  end

end
