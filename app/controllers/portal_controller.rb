# Copyright (C) 2009,2010 Róbert Viðar Bjarnason
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class PortalController < ApplicationController
  before_filter :login_required, :only => [:new, :create, :destroy, :add_portlet, :save_positions, :delete_portlet]
  before_filter :admin_required, :only => [:edit, :update]

  def index
    setup_portal
    
    respond_to do |format|
      format.html # index.html.erb
    end
  end

  def add_portlet
    setup_portal
    portlet=Portlet.new
    portlet.portlet_template_id = get_id_from_menu_url(params[:data])
    portlet.portlet_container_id = @portlet_container.id
    portlet.save
    
    portlet_pos = PortletPosition.new
    portlet_pos.css_column = 1
    portlet_pos.css_position = 0
    portlet_pos.portlet_id = portlet.id
    portlet_pos.save

    portal=@template.escape_javascript(render_to_string :partial=>"portal")
    respond_to do |format|
      format.js do
        render :update do |page|
          page.default_portal_update(portal,@portlet_container,current_user.is_admin?)
        end
      end
    end
  end

  def delete_portlet
    setup_portal

    portlet = Portlet.find(params[:portlet_id].to_i)
    if portlet
      if portlet.portlet_container.default_admin and not current_user.is_admin?
        warn("Regular user trying to delete admin default portlet #{portlet.id}")
      else
        portlet.destroy
      end
    end

    portal=@template.escape_javascript(render_to_string :partial=>"portal")
    respond_to do |format|
      format.js do
        render :update do |page|
          page.default_portal_update(portal,@portlet_container,current_user.is_admin?)
        end
      end
    end
  end
  
  def save_positions
    #redirect_to :no_access and return unless @i_am_admin
    PortletPosition.transaction do
      params.each do |key,value|
         if key.index("portlet_id")
           dp = PortletPosition.find_by_portlet_id(key.split("-")[1].to_i)
           dp.css_column = value.split("|")[0].to_i
           dp.css_position = value.split("|")[1].to_i
           dp.save
         end
      end
    end
    render :nothing=>true
  end  

  private

  def default_container
    portlet_container = PortletContainer.find_by_default_admin(true)
    unless  portlet_container
      portlet_container = PortletContainer.new
      portlet_container.default_admin = true
      portlet_container.save
    end
    portlet_container
  end

  def user_container
    portlet_container = PortletContainer.find_by_user_id(current_user.id)
    unless portlet_container
      portlet_container = PortletContainer.new
      portlet_container.user_id = current_user.id
      portlet_container.save
      portlet_container.clone_from_default(default_container)
    end
    portlet_container
  end

  def setup_portal
    if (current_user.is_admin? and current_user.id == 1) or not current_user.is_logged_in?
      @portlet_container = default_container
    else
      @portlet_container = user_container
    end
  end

  def get_id_from_menu_url(data)
    pos=data.rindex("-")
    data[pos+1..data.length+1].to_i
  end
end
