class EventsController < ApplicationController
  include SquashManyDuplicatesMixin # Provides squash_many_duplicates

  # GET /events
  # GET /events.xml
  def index
    @start_date = date_or_default_for(:start)
    @end_date = date_or_default_for(:end)

    query = Event.non_duplicates.ordered_by_ui_field(params[:order]).includes(:venue, :tags)
    @events = params[:date] ?
                query.within_dates(@start_date, @end_date) :
                query.future

    @perform_caching = params[:order].blank? && params[:date].blank?

    @page_title = "Events"

    render_events @events
  end

  # GET /events/1
  # GET /events/1.xml
  def show
    @event = Event.find(params[:id])
    return redirect_to(@event.progenitor) if @event.duplicate?

    @page_title = @event.title

    render_event @event
  rescue ActiveRecord::RecordNotFound => e
    return redirect_to events_path, flash: { failure: e.to_s }
  end

  # GET /events/new
  # GET /events/new.xml
  def new
    @event = Event.new(params[:event])
    @page_title = "Add an Event"
  end

  # GET /events/1/edit
  def edit
    @event = Event.find(params[:id])
    @page_title = "Editing '#{@event.title}'"
  end

  # POST /events
  # POST /events.xml
  def create
    @event = Event.new
    create_or_update
  end

  # PUT /events/1
  # PUT /events/1.xml
  def update
    @event = Event.find(params[:id])
    create_or_update
  end

  def create_or_update
    @event.attributes = params[:event]
    @event.associate_with_venue(venue_ref(params))
    has_new_venue = @event.venue.try(:new_record?)

    @event.start_time = [ params[:start_date], params[:start_time] ]
    @event.end_time   = [ params[:end_date], params[:end_time] ]

    @event.tags.reload # Reload the #tags association because its members may have been modified when #tag_list was set above.

    if evil_robot = params[:trap_field].present?
      flash[:failure] = "<h3>Evil Robot</h3> We didn't save this event because we think you're an evil robot. If you're really not an evil robot, look at the form instructions more carefully. If this doesn't work please file a bug report and let us know."
    end

    if too_many_links = too_many_links?(@event.description)
      flash[:failure] = "We allow a maximum of 3 links in a description. You have too many links."
    end

    respond_to do |format|
      if !evil_robot && !too_many_links && params[:preview].nil? && @event.save
        flash[:success] = 'Event was successfully updated. '
        format.html {
          if has_new_venue && !params[:venue_name].blank?
            flash[:success] += "Please tell us more about where it's being held."
            redirect_to(edit_venue_url(@event.venue, :from_event => @event.id))
          else
            redirect_to @event
          end
        }
        format.xml  { render :xml => @event, :status => :created, :location => @event }
      else
        @event.valid? if params[:preview]
        format.html { render action: @event.new_record? ? "new" : "edit" }
        format.xml  { render :xml => @event.errors, :status => :unprocessable_entity }
      end
    end
  end

  # DELETE /events/1
  # DELETE /events/1.xml
  def destroy
    @event = Event.find(params[:id])
    @event.destroy

    respond_to do |format|
      format.html { redirect_to(events_url, :flash => {:success => "\"#{@event.title}\" has been deleted"}) }
      format.xml  { head :ok }
    end
  end

  # GET /events/search
  def search
    @search = Event::Search.new(params)

    flash[:failure] = @search.failure_message
    return redirect_to root_path if @search.hard_failure?

    # setting @events so that we can reuse the index atom builder
    @events = @search.events

    @page_title = @search.tag ? "Events tagged with '#{@search.tag}'" : "Search Results for '#{@search.query}'"

    render_events(@events)
  end

  def clone
    @event = Event.find(params[:id]).to_clone
    @page_title = "Clone an existing Event"

    flash[:success] = "This is a new event cloned from an existing one. Please update the fields, like the time and description."
    render "new"
  end

protected

  # Checks if the description has too many links
  # which is probably spam
  def too_many_links?(description)
    description.present? && description.scan(/https?:\/\//i).size > 3
  end

  # Export +events+ to an iCalendar file.
  def ical_export(events=nil)
    events = events || Event.future.non_duplicates
    render(:text => Event.to_ical(events, :url_helper => lambda{|event| event_url(event)}), :mime_type => 'text/calendar')
  end

  def render_event(event)
    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml  => event.to_xml(:include => :venue) }
      format.json { render :json => event.to_json(:include => :venue), :callback => params[:callback] }
      format.ics { ical_export([event]) }
    end
  end

  # Render +events+ for a particular format.
  def render_events(events)
    respond_to do |format|
      format.html # *.html.erb
      format.kml  # *.kml.erb
      format.ics  { ical_export(events) }
      format.atom { render :template => 'events/index' }
      format.xml  { render :xml  => events.to_xml(:include => :venue) }
      format.json { render :json => events.to_json(:include => :venue), :callback => params[:callback] }
    end
  end

  # Venues may be referred to in the params hash either by id or by name. This
  # method looks for whichever type of reference is present and returns that
  # reference. If both a venue id and a venue name are present, then the venue
  # id is returned.
  #
  # If a venue id is returned it is cast to an integer for compatibility with
  # Event#associate_with_venue.
  def venue_ref(p)
    if (p[:event] && !p[:event][:venue_id].blank?)
      p[:event][:venue_id].to_i
    else
      p[:venue_name]
    end
  end

  # Return the default start date.
  def default_start_date
    Time.zone.today
  end

  # Return the default end date.
  def default_end_date
    Time.zone.today + 3.months
  end

  # Return a date parsed from user arguments or a default date. The +kind+
  # is a value like :start, which refers to the `params[:date][+kind+]` value.
  # If there's an error, set an error message to flash.
  def date_or_default_for(kind)
    if params[:date].present?
      if params[:date].respond_to?(:has_key?)
        if params[:date].has_key?(kind)
          if params[:date][kind].present?
            begin
              return Date.parse(params[:date][kind])
            rescue ArgumentError => e
              append_flash :failure, "Can't filter by an invalid #{kind} date."
            end
          else
            append_flash :failure, "Can't filter by an empty #{kind} date."
          end
        else
          append_flash :failure, "Can't filter by a missing #{kind} date."
        end
      else
        append_flash :failure, "Can't filter by a malformed #{kind} date."
      end
    end
    return self.send("default_#{kind}_date")
  end
end
