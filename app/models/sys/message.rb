class Sys::Message < ApplicationRecord
  include Sys::Model::Base
  include Sys::Model::Rel::Creator
  include Cms::Model::Rel::Site
  include Cms::Model::Auth::Site

  enum_ish :state, [:public, :closed]

  belongs_to :site, class_name: 'Cms::Site'

  validates :state, :published_at, :title, :body, presence: true
end
