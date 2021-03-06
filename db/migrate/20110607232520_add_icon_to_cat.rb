class AddIconToCat < ActiveRecord::Migration
  def self.up
    add_column :categories, :icon_file_name, :string
    add_column :categories, :icon_content_type, :string, :limit => 30
    add_column :categories, :icon_file_size, :integer
    add_column :categories, :icon_updated_at, :datetime        
  end

  def self.down
  end
end
