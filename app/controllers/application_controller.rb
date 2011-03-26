# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

class ApplicationController < ActionController::Base
  include Tr8n::CommonMethods
  include AuthenticatedSystem
  include FaceboxRender

  include Facebooker2::Rails::Controller

  require_dependency "activity.rb"
  require_dependency "blast.rb" 
  require_dependency "relationship.rb"   
  require_dependency "capital.rb"

#  rescue_from ActionController::InvalidAuthenticityToken, :with => :bad_token

  helper :all # include all helpers, all the time
  
  # Make these methods visible to views as well
  helper_method :current_facebook_user, :government_cache, :current_partner, :current_user_endorsements, :current_priority_ids, :current_following_ids, :current_ignoring_ids, :current_following_facebook_uids, :current_government, :current_tags, :facebook_session, :is_robot?, :js_help
  
  # switch to the right database for this government
  before_filter :check_subdomain
  before_filter :check_geoblocking
  
  before_filter :load_actions_to_publish, :unless => [:is_robot?]
#  before_filter :check_facebook, :unless => [:is_robot?]
    
  before_filter :check_blast_click, :unless => [:is_robot?]
  before_filter :check_priority, :unless => [:is_robot?]
  before_filter :check_referral, :unless => [:is_robot?]
  before_filter :check_suspension, :unless => [:is_robot?]
  before_filter :update_loggedin_at, :unless => [:is_robot?]

  before_filter :check_google_translate_setting

  before_filter :init_tr8n

  layout :get_layout

  # See ActionController::RequestForgeryProtection for details
  # Uncomment the :secret if you're not using the cookie session store
  #protect_from_forgery #:secret => 'd0451bc51967070c0872c2865d2651e1'

  protected

  JS_ESCAPE_MAP = {
        '\\'    => '\\\\',
        '</'    => '<\/',
        "\r\n"  => '\n',
        "\n"    => '\n',
        "\r"    => '\n',
        '"'     => '\\"',
        "'"     => "\\'" }
        
  def unfrozen_instance(object)
    eval "#{object.class}.where(:id=>object.id).first"
  end
        
  def escape_javascript(javascript)
    if javascript
      javascript.gsub(/(\\|<\/|\r\n|[\n\r"'])/) { JS_ESCAPE_MAP[$1] }
    else
      ''
    end
  end  
  
  def check_geoblocking
    @country_code = Thread.current[:country_code] = (session[:country_code] ||= GeoIP.new(Rails.root.join("lib/geoip/GeoIP.dat")).country(request.remote_ip)[3]).downcase
    if Partner.current and Partner.current.geoblocking_enabled
      logged_in_user = current_user
      unless Partner.current.geoblocking_disabled_for?(@country_code)
        @geoblocked = true
      end
      if logged_in_user and not logged_in_user.geoblocking_disabled_for?(@country_code)
        @geoblocked = false
      end
    end
  end
  
  def current_locale
    if params[:locale]
      session[:locale] = params[:locale]
    elsif not session[:locale]
      if Partner.current and Partner.current.default_locale
        session[:locale] = Partner.current.default_locale
      else
        session[:locale] = tr8n_user_preffered_locale
      end
    end
    I18n.locale = ENABLED_I18_LOCALES.include?(session[:locale]) ? session[:locale] : "en"
    tr8n_current_locale = session[:locale]
  end

  def check_google_translate_setting
    if params[:gt]
      if params[:gt]=="1"
        session[:enable_google_translate] = true
      else
        session[:enable_google_translate] = nil
      end
    end
    
    @google_translate_enabled_for_locale = tr8n_current_google_language_code
  end
  
  def get_layout
    return false if not is_robot? and not current_government
    return "basic" if not Government.current
    return Government.current.layout
  end

  def current_government
    return @current_government if @current_government
    @current_government = Rails.cache.read('government')
    if not @current_government
      @current_government = Government.last
      if @current_government
        @current_government.update_counts
        Rails.cache.write('government', @current_government, :expires_in => 15.minutes) 
      else
        return nil
      end
    end
    Government.current = @current_government
    return @current_government
  end
  
  # Will either fetch the current partner or return nil if there's no subdomain
  def current_partner
    if request.subdomains.size == 0 or request.host == current_government.base_url or request.subdomains.first == 'www'
      @current_partner = nil
      Partner.current = @current_partner
      return nil
    else
      @current_partner ||= Partner.find_by_short_name(request.subdomains.first)
      Partner.current = @current_partner
      return @current_partner
    end
  end
  
  def current_user_endorsements
		@current_user_endorsements ||= current_user.endorsements.active.by_position.paginate(:include => :priority, :page => session[:endorsement_page], :per_page => 25)
  end
  
  def current_priority_ids
    return [] unless logged_in? and current_user.endorsements_count > 0
    @current_priority_ids ||= current_user.endorsements.active_and_inactive.collect{|e|e.priority_id}
  end  
  
  def current_following_ids
    return [] unless logged_in? and current_user.followings_count > 0
    @current_following_ids ||= current_user.followings.up.collect{|f|f.other_user_id}
  end
  
  def current_following_facebook_uids
    return [] unless logged_in? and current_user.followings_count > 0 and current_user.has_facebook?
    @current_following_facebook_uids ||= current_user.followings.up.collect{|f|f.other_user.facebook_uid}.compact
  end  
  
  def current_ignoring_ids
    return [] unless logged_in? and current_user.ignorings_count > 0
    @current_ignoring_ids ||= current_user.followings.down.collect{|f|f.other_user_id}    
  end
  
  def current_tags
    return [] unless current_government.is_tags?
    @current_tags ||= Rails.cache.fetch('Tag.by_endorsers_count.all') { Tag.by_endorsers_count.all }
  end

  def load_actions_to_publish
    @user_action_to_publish = flash[:user_action_to_publish] 
    flash[:user_action_to_publish]=nil
  end  
  
  def check_suspension
    if logged_in? and current_user and current_user.status == 'suspended'
      self.current_user.forget_me if logged_in?
      cookies.delete :auth_token
      reset_session
      flash[:notice] = "This account has been suspended."
      redirect_back_or_default('/')
      return  
    end
  end
  
  # they were trying to endorse a priority, so let's go ahead and add it and take htem to their priorities page immediately    
  def check_priority
    return unless logged_in? and session[:priority_id]
    @priority = Priority.find(session[:priority_id])
    @value = session[:value].to_i
    if @priority
      if @value == 1
        @priority.endorse(current_user,request,current_partner,@referral)
      else
        @priority.oppose(current_user,request,current_partner,@referral)
      end
    end  
    session[:priority_id] = nil
    session[:value] = nil
  end
  
  def update_loggedin_at
    return unless logged_in?
    return unless current_user.loggedin_at.nil? or Time.now > current_user.loggedin_at+30.minutes
    begin
      User.find(current_user.id).update_attribute(:loggedin_at,Time.now)
    rescue
    end
  end

  def check_blast_click
    # if they've got a ?b= code, log them in as that user
    if params[:b] and params[:b].length > 2
      @blast = Blast.find_by_code(params[:b])
      if @blast and not logged_in?
        self.current_user = @blast.user
        @blast.increment!(:clicks_count)
      end
      redirect = request.path_info.split('?').first
      redirect = "/" if not redirect
      redirect_to redirect
      return
    end
  end

  def check_subdomain
    if not current_government
      redirect_to :controller => "install"
      return
    end
    if not current_partner and Rails.env == 'production' and request.subdomains.any? and not ['www','dev'].include?(request.subdomains.first) and current_government.base_url != request.host
      redirect_to 'http://' + current_government.base_url + request.path_info
      return
    end    
  end
  
  def check_referral
    if not params[:referral_id].blank?
      @referral = User.find(params[:referral_id])
    else
      @referral = nil
    end    
  end  
  
  # if they're logged in with our account, AND connected with facebook, but don't have their facebook uid added to their account yet
  def check_facebook 
    if logged_in? and current_facebook_user
      unless current_user.facebook_uid
        @user = User.find(current_user.id)
        if not @user.update_with_facebook(current_facebook_user)
          return
        end
        if not @user.activated?
          @user.activate!
        end      
        @current_user = User.find(current_user.id)
        flash.now[:notice] = tr("Your account is now synced with Facebook. In the future, to sign in, simply click the big blue Facebook button.", "controller/application", :government_name => current_government.name)
      end
    end      
  end
  
  def is_robot?
    return true if request.format == 'rss' or params[:controller] == 'pictures'
    request.user_agent =~ /\b(Baidu|Gigabot|Googlebot|libwww-perl|lwp-trivial|msnbot|SiteUptime|Slurp|WordPress|ZIBB|ZyBorg)\b/i
  end
  
  def no_facebook?
    return false if logged_in? and current_facebook_user
    return true
  end
  
  def bad_token
    flash[:error] = tr("Sorry, that last page already expired. Please try what you were doing again.", "controller/application")
    respond_to do |format|
      format.html { redirect_to request.referrer||'/' }
      format.js { redirect_from_facebox(request.referrer||'/') }
    end
  end
  
  def fb_session_expired
    self.current_user.forget_me if logged_in?
    cookies.delete :auth_token
    reset_session    
    flash[:error] = tr("Your Facebook session expired.", "controller/application")
    respond_to do |format|
      format.html { redirect_to '/portal/' }
      format.js { redirect_from_facebox(request.referrer||'/') }
    end    
  end
  
  def js_help
    JavaScriptHelper.instance
  end

  class JavaScriptHelper
    include Singleton
    include ActionView::Helpers::JavaScriptHelper
  end  
end

module FaceboxRender
   
  def render_to_facebox( options = {} )
    options[:template] = "#{default_template_name}" if options.empty?

    action_string = render_to_string(:action => options[:action], :layout => "facebox") if options[:action]
    template_string = render_to_string(:template => options[:template], :layout => "facebox") if options[:template]

    render :update do |page|
      page << "jQuery.facebox(#{action_string.to_json})" if options[:action]
      page << "jQuery.facebox(#{template_string.to_json})" if options[:template]
      page << "jQuery.facebox(#{(render :partial => options[:partial]).to_json})" if options[:partial]
      page << "jQuery.facebox(#{options[:html].to_json})" if options[:html]

      if options[:msg]
        page << "jQuery('#facebox .content').prepend('<div class=\"message\">#{options[:msg]}</div>')"
      end
      page << render(:partial => "shared/javascripts_reloadable")
      
      yield(page) if block_given?

    end
  end
    
end