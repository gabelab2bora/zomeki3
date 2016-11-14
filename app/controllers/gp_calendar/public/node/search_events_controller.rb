class GpCalendar::Public::Node::SearchEventsController < GpCalendar::Public::Node::BaseController
  skip_after_action :render_public_layout, :only => [:file_content]

  def index
    http_error(404) if params[:page]

    year_month = @year_only ? @date.strftime('%Y') : @date.strftime('%Y%m')

    criteria = {year_month: year_month}
    @events = GpCalendar::Event.public_state.content_and_criteria(@content, criteria).order(:started_on)
      .preload(:categories).to_a

    start_date, end_date = if @year_only
                             boy = @date.beginning_of_year
                             boy = @min_date if @min_date > boy
                             eoy = @date.end_of_year
                             eoy = @max_date if @max_date < eoy
                             [boy, eoy]
                           else
                             [@date.beginning_of_month, @date.end_of_month]
                           end
    merge_docs_into_events(event_docs(start_date, nil), @events)

    @holidays = GpCalendar::Holiday.public_state.content_and_criteria(@content, criteria).where(kind: :event)
    @holidays.each do |holiday|
      holiday.started_on = @date.year
      @events << holiday if holiday.started_on
    end
    @events.sort! {|a, b| a.started_on <=> b.started_on}

    filter_events_by_specified_category(@events)
  end

  def file_content
    @event = @content.events.find_by(name: params[:name])
    return http_error(404) unless @event
    file = @event.files.find_by(name: "#{params[:basename]}.#{params[:extname]}")
    return http_error(404) unless file

    mt = file.mime_type.presence || Rack::Mime.mime_type(File.extname(file.name))
    type, disposition = (mt =~ %r!^image/|^application/pdf$! ? [mt, 'inline'] : [mt, 'attachment'])
    disposition = 'attachment' if request.env['HTTP_USER_AGENT'] =~ /Android/
    send_file file.upload_path, :type => type, :filename => file.name, :disposition => disposition
  end

end
