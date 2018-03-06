module Sys::Model::Base
  extend ActiveSupport::Concern
  include Sys::Model::Scope
  include Sys::Model::Validation

  included do
    self.table_name = self.to_s.underscore.gsub('/', '_').downcase.pluralize
  end
end
