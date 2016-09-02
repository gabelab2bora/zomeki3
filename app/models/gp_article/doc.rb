class GpArticle::Doc < ActiveRecord::Base
  include Sys::Model::Base
  include Sys::Model::Base::OperationLog
  include Sys::Model::Rel::Creator
  include Sys::Model::Rel::Editor
  include Sys::Model::Rel::EditableGroup
  include Sys::Model::Rel::File
  include Sys::Model::Rel::Task
  include Cms::Model::Base::Page
  include Cms::Model::Base::Page::Publisher
  include Cms::Model::Base::Page::TalkTask
  include Cms::Model::Rel::ManyInquiry
  include Cms::Model::Rel::Map

  include Cms::Model::Auth::Concept
  include Sys::Model::Auth::EditableGroup

  include GpArticle::Model::Rel::Doc
  include GpArticle::Model::Rel::Category
  include GpArticle::Model::Rel::Sns
  include GpArticle::Model::Rel::Tag
  include Approval::Model::Rel::Approval
  include GpTemplate::Model::Rel::Template

  include StateText
  include GpArticle::Docs::PublishQueue
  include GpArticle::Docs::Preload

  STATE_OPTIONS = [['下書き保存', 'draft'], ['承認依頼', 'approvable'], ['即時公開', 'public']]
  TARGET_OPTIONS = [['無効', ''], ['同一ウィンドウ', '_self'], ['別ウィンドウ', '_blank'], ['添付ファイル', 'attached_file']]
  EVENT_STATE_OPTIONS = [['表示', 'visible'], ['非表示', 'hidden']]
  MARKER_STATE_OPTIONS = [['表示', 'visible'], ['非表示', 'hidden']]
  OGP_TYPE_OPTIONS = [['article', 'article']]
  SHARE_TO_SNS_WITH_OPTIONS = [['OGP', 'og_description'], ['記事の内容', 'body']]
  FEATURE_1_OPTIONS = [['表示', true], ['非表示', false]]
  FEATURE_2_OPTIONS = [['表示', true], ['非表示', false]]
  QRCODE_OPTIONS = [['表示', 'visible'], ['非表示', 'hidden']]
  EVENT_WILL_SYNC_OPTIONS = [['同期する', 'enabled'], ['同期しない', 'disabled']]

  default_scope { where.not(state: 'archived') }
  scope :public_state, -> { where(state: 'public') }
  scope :mobile, ->(m) { m ? where(terminal_mobile: true) : where(terminal_pc_or_smart_phone: true) }
  scope :display_published_after, ->(date) { where(arel_table[:display_published_at].gteq(date)) }

  # Content
  belongs_to :content, :foreign_key => :content_id, :class_name => 'GpArticle::Content::Doc'
  validates :content_id, :presence => true

  # Page
  belongs_to :concept, :foreign_key => :concept_id, :class_name => 'Cms::Concept'
  belongs_to :layout, :foreign_key => :layout_id, :class_name => 'Cms::Layout'

  belongs_to :prev_edition, :class_name => self.name
  has_one :next_edition, :foreign_key => :prev_edition_id, :class_name => self.name

  belongs_to :marker_icon_category, :class_name => 'GpCategory::Category'

  has_many :categorizations, :class_name => 'GpCategory::Categorization', :as => :categorizable, :dependent => :destroy
  has_many :categories, -> { where(GpCategory::Categorization.arel_table[:categorized_as].eq('GpArticle::Doc')) },
           :class_name => 'GpCategory::Category', :through => :categorizations,
           :after_add => proc {|d, c|
             d.categorizations.where(category_id: c.id, categorized_as: nil).first.update_columns(categorized_as: d.class.name)
           }
  has_many :event_categories, -> { where(GpCategory::Categorization.arel_table[:categorized_as].eq('GpCalendar::Event')) },
           :class_name => 'GpCategory::Category', :through => :categorizations, :source => :category,
           :after_add => proc {|d, c|
             d.categorizations.where(category_id: c.id, categorized_as: nil).first.update_columns(categorized_as: 'GpCalendar::Event')
           }
  has_many :marker_categories, -> { where(GpCategory::Categorization.arel_table[:categorized_as].eq('Map::Marker')) },
           :class_name => 'GpCategory::Category', :through => :categorizations, :source => :category,
           :after_add => proc {|d, c|
             d.categorizations.where(category_id: c.id, categorized_as: nil).first.update_columns(categorized_as: 'Map::Marker')
           }
  has_and_belongs_to_many :tags, ->(doc) {
                              c = doc.content
                              c && c.tag_related? && c.tag_content_tag ? where(content_id: c.tag_content_tag.id) : where(id: nil)
                            }, class_name: 'Tag::Tag', join_table: 'gp_article_docs_tag_tags'

  has_many :holds, :as => :holdable, :dependent => :destroy
  has_many :links, :dependent => :destroy
  has_many :comments, :dependent => :destroy

  has_many :sns_shares, :class_name => 'SnsShare::Share', :as => :sharable, :dependent => :destroy
  has_many :sns_accounts, :class_name => 'SnsShare::Account', :through => :sns_shares, :source => :account

  before_save :make_file_contents_path_relative
  before_save :set_name
  before_save :set_published_at
  before_save :replace_public
  before_save :set_serial_no
  before_destroy :keep_edition_relation
  after_destroy :close_page

  validates :title, :presence => true, :length => {maximum: 200}
  validates :mobile_title, :length => {maximum: 200}
  validates :body, :length => {maximum: 300000}
  validates :mobile_body, :length => {maximum: 300000}
  validates :state, :presence => true
  validates :filename_base, :presence => true

  validate :name_validity
  validate :node_existence
  validate :event_dates_range
  validate :broken_link_existence, :unless => :state_draft?
  validate :body_limit_for_mobile
  validate :validate_accessibility_check, :unless => :state_draft?

  after_initialize :set_defaults
  after_save :set_display_attributes
  after_save :save_links

  attr_accessor :ignore_accessibility_check

  scope :event_scheduled_between, ->(start_date, end_date) {
    where(arel_table[:event_ended_on].gteq(start_date)).where(arel_table[:event_started_on].lt(end_date + 1))
  }

  scope :content_and_criteria, ->(content, criteria){
    docs = self.arel_table

    creators = Sys::Creator.arel_table

    rel = if criteria[:group].blank? && criteria[:group_id].blank? && criteria[:user].blank?
            joins(:creator)
          else
            inners = []

            if criteria[:group].present? || criteria[:group_id].present?
              groups = Sys::Group.arel_table
              inners << :group
            end

            if criteria[:user].present?
              users = Sys::User.arel_table
              inners << :user
            end

            self.joins(:creator => inners)
          end

    rel = rel.where(docs[:content_id].eq(content.id)) if content.kind_of?(GpArticle::Content::Doc)

    rel = rel.where(docs[:id].eq(criteria[:id])) if criteria[:id].present?
    rel = rel.where(docs[:state].eq(criteria[:state])) if criteria[:state].present?
    rel = rel.search_with_text(:title, criteria[:title]) if criteria[:title].present?
    rel = rel.search_with_text(:title, :body, :name, criteria[:free_word]) if criteria[:free_word].present?
    rel = rel.where(groups[:name].matches("%#{criteria[:group]}%")) if criteria[:group].present?
    if criteria[:group_id].present?
      rel = rel.where(if criteria[:group_id].kind_of?(Array)
                        groups[:id].in(criteria[:group_id])
                      else
                        groups[:id].eq(criteria[:group_id])
                      end)
    end
    rel = rel.where(users[:name].matches("%#{criteria[:user]}%")
                    .or(users[:name_en].matches("%#{criteria[:user]}%"))) if criteria[:user].present?

    if criteria[:touched_user_id].present?
      operation_logs = Sys::OperationLog.arel_table

      rel = rel.eager_load(:operation_logs)
                .where(operation_logs[:user_id].eq(criteria[:touched_user_id])
                .or(creators[:user_id].eq(criteria[:touched_user_id])))
    end

    if criteria[:editable].present?
      editable_groups = Sys::EditableGroup.arel_table

      rel = unless Core.user.has_auth?(:manager)
              rel.eager_load(:editable_group)
                  .where(creators[:group_id].eq(Core.user.group.id)
                  .or(editable_groups[:all].eq(true)
                  .or(editable_groups[:group_ids].eq(Core.user.group.id.to_s)
                  .or(editable_groups[:group_ids].matches("#{Core.user.group.id} %")
                  .or(editable_groups[:group_ids].matches("% #{Core.user.group.id} %")
                  .or(editable_groups[:group_ids].matches("% #{Core.user.group.id}")))))))
            else
              rel
            end
    end

    if criteria[:approvable].present?
      approval_requests = Approval::ApprovalRequest.arel_table
      assignments = Approval::Assignment.arel_table
      rel = rel.joins(:approval_requests => [:approval_flow => [:approvals => :assignments]])
               .where(approval_requests[:user_id].eq(Core.user.id)
                      .or(assignments[:user_id].eq(Core.user.id))).distinct
    end

    return rel
  }
  scope :categorized_into, ->(category_ids) {
    cats = GpCategory::Categorization.arel_table
    where(id: GpCategory::Categorization.select(:categorizable_id)
      .where(cats[:categorized_as].eq('GpArticle::Doc'))
      .where(cats[:category_id].in(category_ids))
      .order(cats[:sort_no].eq(nil), cats[:sort_no].asc))
  }
  scope :organized_into, ->(group_ids) {
    groups = Sys::Group.arel_table
    joins(creator: :group).where(groups[:id].in(group_ids))
  }

  def public_comments
    comments.public_state
  end

  def prev_edition
    self.class.unscoped { super }
  end

  def prev_editions(docs=[])
    docs << self
    prev_edition.prev_editions(docs) if prev_edition
    return docs
  end

  def next_edition
    self.class.unscoped { super }
  end

  def next_editions(docs=[])
    docs << self
    next_edition.next_editions(docs) if next_edition
    return docs
  end

  def public_path
    return '' if public_uri.blank?
    "#{content.public_path}#{public_uri(without_filename: true)}#{filename_base}.html"
  end

  def public_smart_phone_path
    return '' if public_uri.blank?
    "#{content.public_path}/_smartphone#{public_uri(without_filename: true)}#{filename_base}.html"
  end

  def organization_content_related?
    organization_content = content.organization_content_group
    return organization_content &&
      organization_content.article_related? &&
      organization_content.related_article_content_id == content.id
  end

  def organization_group
    return @organization_group if defined? @organization_group
    @organization_group =
      if content.organization_content_group && creator.group
        content.organization_content_group.groups.detect{|og| og.sys_group_code == creator.group.code}
      else
        nil
      end
  end

  def public_uri(without_filename: false)
    uri =
      if organization_content_related? && organization_group
        "#{organization_group.public_uri}docs/#{name}/"
      elsif content.public_node
        "#{content.public_node.public_uri}#{name}/"
      end
    return '' unless uri
    without_filename || filename_base == 'index' ? uri : "#{uri}#{filename_base}.html"
  end

  def public_full_uri(without_filename: false)
    uri =
      if organization_content_related? && organization_group
        "#{organization_group.public_full_uri}docs/#{name}/"
      elsif content.public_node
        "#{content.public_node.public_full_uri}#{name}/"
      end
    return '' unless uri
    without_filename || filename_base == 'index' ? uri : "#{uri}#{filename_base}.html"
  end

  def preview_uri(site: nil, mobile: false, without_filename: false, **params)
    return nil unless public_uri(without_filename: true)
    site ||= ::Page.site
    params = params.map{|k, v| "#{k}=#{v}" }.join('&')
    filename = without_filename || filename_base == 'index' ? '' : "#{filename_base}.html"

    path = "_preview/#{format('%04d', site.id)}#{mobile ? 'm' : ''}#{public_uri(without_filename: true)}preview/#{id}/#{filename}#{params.present? ? "?#{params}" : ''}"
    d = Cms::SiteSetting::AdminProtocol.core_domain site, :freeze_protocol => true
    "#{d}#{path}"
  end

  def state_options
    options = if Core.user.has_auth?(:manager) || content.save_button_states.include?('public')
                STATE_OPTIONS
              else
                STATE_OPTIONS.reject{|so| so.last == 'public' }
              end
    if content.approval_related?
      options
    else
      options.reject{|o| o.last == 'approvable' }
    end
  end

  def state_draft?
    state == 'draft'
  end

  def state_approvable?
    state == 'approvable'
  end

  def state_approved?
    state == 'approved'
  end

  def state_public?
    state == 'public'
  end

  def state_closed?
    state == 'closed'
  end

  def state_archived?
    state == 'archived'
  end

  def close
    @save_mode = :close
    self.state = 'closed' if self.state_public?
    return false unless save(:validate => false)
    close_page
    return true
  end

  def close_page(options={})
    return true if will_replace?
    return false unless super
    publishers.destroy_all unless publishers.empty?
    if p = public_path
      FileUtils.rm_rf(::File.dirname(public_path)) unless p.blank?
    end
    if p = public_smart_phone_path
      FileUtils.rm_rf(::File.dirname(public_smart_phone_path)) unless p.blank?
    end
    return true
  end

  def publish(content)
    @save_mode = :publish
    self.state = 'public' unless self.state_public?
    return false unless save(:validate => false)
    publish_page(content, path: public_path, uri: public_uri)
    publish_files
    publish_qrcode
  end

  def rebuild(content, options={})
    if options[:dependent] == :smart_phone
      return false unless self.content.site.publish_for_smart_phone?
      return false unless self.content.site.spp_all?
    end

    return false unless self.state_public?
    @save_mode = :publish
    publish_page(content, options)
    #TODO: スマートフォン向けファイル書き出し要再検討
    @public_files_path = "#{::File.dirname(public_smart_phone_path)}/file_contents" if options[:dependent] == :smart_phone
    @public_qrcode_path = "#{::File.dirname(public_smart_phone_path)}/qrcode.png" if options[:dependent] == :smart_phone
    result = publish_files
    publish_qrcode
    @public_files_path = nil if options[:dependent] == :smart_phone
    @public_qrcode_path = nil if options[:dependent] == :smart_phone
    return result
  end

  def bread_crumbs(doc_node)
    crumbs = []

    categories.public_state.each do |category|
      category_type = category.category_type
      if (node = category.content.category_type_node)
        crumb = node.bread_crumbs.crumbs.first
        crumb << [category_type.title, "#{node.public_uri}#{category_type.name}/"]
        category.ancestors.each {|a| crumb << [a.title, "#{node.public_uri}#{category_type.name}/#{a.path_from_root_category}/"] }
        crumbs << crumb
      end
    end

    if crumbs.empty?
      doc_node.routes.each do |r|
        crumb = []
        r.each {|i| crumb << [i.title, i.public_uri] }
        crumbs << crumb
      end
    end

    Cms::Lib::BreadCrumbs.new(crumbs)
  end

  def duplicate(dup_for=nil)
    new_attributes = self.attributes

    new_attributes[:state] = 'draft'
    new_attributes[:id] = nil
    new_attributes[:created_at] = nil
    new_attributes[:prev_edition_id] = nil

    new_doc = self.class.new(new_attributes)

    case dup_for
    when :replace
      new_doc.prev_edition = self
      new_doc.in_tasks = self.in_tasks
      new_doc.in_creator = {'group_id' => creator.group_id, 'user_id' => creator.user_id}
    else
      new_doc.name = nil
      new_doc.title = new_doc.title.gsub(/^(【複製】)*/, '【複製】')
      new_doc.updated_at = nil
      new_doc.display_updated_at = nil
      new_doc.published_at = nil
      new_doc.display_published_at = nil
      new_doc.in_tasks = nil
      new_doc.serial_no = nil
    end

    if editable_group
      gids = editable_group.group_ids.split
      gids << 'ALL' if editable_group.all
      new_doc.in_editable_groups = gids
    end

    inquiries.each_with_index do |inquiry, i|
      attrs = inquiry.attributes
      attrs[:id] = nil
      attrs[:group_id] = Core.user.group_id if i == 0
      new_doc.inquiries.build(attrs)
    end

    unless maps.empty?
      new_maps = {}
      maps.each_with_index do |m, i|
        new_markers = {}
        m.markers.each_with_index do |mm, j|
          new_markers[j.to_s] = {
           'name' => mm.name,
           'lat'  => mm.lat,
           'lng'  => mm.lng
          }.with_indifferent_access
        end

        new_maps[i.to_s] = {
          'name'     => m.name,
          'title'    => m.title,
          'map_lat'  => m.map_lat,
          'map_lng'  => m.map_lng,
          'map_zoom' => m.map_zoom,
          'markers'  => new_markers
        }.with_indifferent_access
      end
      new_doc.in_maps = new_maps
    end

    new_doc.save!

    files.each do |f|
      new_attributes = f.attributes
      new_attributes[:id] = nil
      Sys::File.new(new_attributes).tap do |new_file|
        new_file.file = Sys::Lib::File::NoUploadedFile.new(f.upload_path, :mime_type => new_file.mime_type)
        new_file.file_attachable = new_doc
        new_file.save
      end
    end

    new_doc.categories = self.categories
    new_doc.event_categories = self.event_categories
    new_doc.marker_categories = self.marker_categories
    new_doc.categorizations.each do |new_c|
      self_c = self.categorizations.where(category_id: new_c.category_id, categorized_as: new_c.categorized_as).first
      new_c.update_column(:sort_no, self_c.sort_no)
    end

    new_doc.sns_accounts = self.sns_accounts

    return new_doc
  end

  def editable?
    result = super
    return result unless result.nil? # See "Sys::Model::Auth::EditableGroup"
    return editable_group.all? || approval_participators.include?(Core.user)
  end

  def publishable?
    super || approval_participators.include?(Core.user)
  end

  def formated_display_published_at
    display_published_at.try(:strftime, content.date_style)
  end

  def formated_display_updated_at
    display_updated_at.try(:strftime, content.date_style)
  end

  def default_map_position
    content.setting_extra_value(:map_relation, :lat_lng).presence || super
  end

  def links_in_body(all=false)
    extract_links(self.body, all)
  end

  def check_links_in_body
    check_results = check_links(links_in_body)
    @broken_link_exists_in_body = check_results.any? {|r| !r[:result] }
    return check_results
  end

  def links_in_mobile_body(all=false)
    extract_links(self.mobile_body, all)
  end

  def links_in_string(str, all=false)
    extract_links(str, all)
  end

  def broken_link_exists?
    @broken_link_exists_in_body
  end

  def backlinks
    return self.class.none unless state_public? || state_closed?
    return self.class.none if public_uri.blank?
    links.engine.where(links.table[:url].matches("%#{self.public_uri(without_filename: true).sub(/\/$/, '')}%"))
  end

  def backlinked_docs
    return [] if backlinks.blank?
    self.class.where(id: backlinks.pluck(:doc_id))
  end

  def validate_word_dictionary
    dic = content.setting_value(:word_dictionary)
    return if dic.blank?

    words = []
    dic.split(/\r\n|\n/).each do |line|
      next if line !~ /,/
      data = line.split(/,/)
      words << [data[0].strip, data[1].strip]
    end

    if body.present?
      words.each {|src, dst| self.body = body.gsub(src, dst) }
    end
    if mobile_body.present?
      words.each {|src, dst| self.mobile_body = mobile_body.gsub(src, dst) }
    end
  end

  def body_for_mobile
    body_doc = Nokogiri::XML("<bory_root>#{self.mobile_body.presence || self.body}</bory_root>")
    body_doc.xpath('//img').each {|img| img.replace(img.attribute('alt').try(:value).to_s) }
    body_doc.xpath('//a').each {|a| a.replace(a.text) if a.attribute('href').try(:value) =~ %r!^file_contents/! }
    body_doc.xpath('/bory_root').to_xml.gsub(%r!^<bory_root>|</bory_root>$!, '')
  end

  def will_replace?
    prev_edition && (state_draft? || state_approvable? || state_approved?)
  end

  def will_be_replaced?
    next_edition && state_public?
  end

  def was_replaced?
    prev_edition && (state_public? || state_closed?)
  end

  def qrcode_visible?
    return false unless content && content.qrcode_related?
    return false unless self.qrcode_state == 'visible'
    return true
  end

  def og_type_text
    OGP_TYPE_OPTIONS.detect{|o| o.last == self.og_type }.try(:first).to_s
  end

  def target_text
    TARGET_OPTIONS.detect{|o| o.last == self.target }.try(:first).to_s
  end

  def event_state_text
    EVENT_STATE_OPTIONS.detect{|o| o.last == self.event_state }.try(:first).to_s
  end

  def marker_state_text
    MARKER_STATE_OPTIONS.detect{|o| o.last == self.marker_state }.try(:first).to_s
  end

  def feature_1_text
    FEATURE_1_OPTIONS.detect{|o| o.last == self.feature_1 }.try(:first).to_s
  end

  def feature_2_text
    FEATURE_2_OPTIONS.detect{|o| o.last == self.feature_2 }.try(:first).to_s
  end

  def qrcode_state_text
    QRCODE_OPTIONS.detect{|o| o.last == self.qrcode_state }.try(:first).to_s
  end

  def public_files_path
    return @public_files_path if @public_files_path
    "#{::File.dirname(public_path)}/file_contents"
  end


  def qrcode_path
    return @public_qrcode_path if @public_qrcode_path
    "#{::File.dirname(public_path)}/qrcode.png"
  end

  def qrcode_uri(preview: false)
    if preview
      "#{preview_uri(without_filename: true)}qrcode.png"
    else
      "#{public_uri(without_filename: true)}qrcode.png"
    end
  end

  def event_will_sync?
    event_will_sync == 'enabled'
  end

  def event_will_sync_text
    EVENT_WILL_SYNC_OPTIONS.detect{|o| o.last == event_will_sync }.try(:first).to_s
  end
  
  def event_state_visible?
    event_state == 'visible'
  end

  private

  def name_validity
    if prev_edition
      self.name = prev_edition.name
      return
    end

    errors.add(:name, :invalid) if self.name && self.name !~ /^[\-\w]*$/

    if (doc = self.class.where(name: self.name, state: self.state, content_id: self.content.id).first)
      unless doc.id == self.id || state_archived?
        errors.add(:name, :taken) unless state_public? && prev_edition.try(:state_public?)
      end
    end
  end

  def set_name
    return if self.name.present?
    date = if created_at
             created_at.strftime('%Y%m%d')
           else
             Date.strptime(Core.now, '%Y-%m-%d').strftime('%Y%m%d')
           end
    seq = Util::Sequencer.next_id('gp_article_docs', :version => date)
    self.name = Util::String::CheckDigit.check(date + format('%04d', seq))
  end

  def set_published_at
    self.published_at ||= Core.now if self.state == 'public'
  end

  def set_defaults
    self.target       ||= TARGET_OPTIONS.first.last if self.has_attribute?(:target)
    self.event_state  ||= 'hidden'                  if self.has_attribute?(:event_state)
    self.marker_state ||= 'hidden'                  if self.has_attribute?(:marker_state)
    self.terminal_pc_or_smart_phone = true if self.has_attribute?(:terminal_pc_or_smart_phone) && self.terminal_pc_or_smart_phone.nil?
    self.terminal_mobile            = true if self.has_attribute?(:terminal_mobile) && self.terminal_mobile.nil?
    self.share_to_sns_with ||= SHARE_TO_SNS_WITH_OPTIONS.first.last if self.has_attribute?(:share_to_sns_with)
    self.body_more_link_text ||= '続きを読む' if self.has_attribute?(:body_more_link_text)
    self.filename_base ||= 'index' if self.has_attribute?(:filename_base)

    set_defaults_from_content if new_record?
  end

  def set_defaults_from_content
    return unless content

    self.qrcode_state = content.qrcode_default_state if self.has_attribute?(:qrcode_state) && self.qrcode_state.nil?
    self.event_will_sync ||= content.event_sync_default_will_sync if self.has_attribute?(:event_will_sync)
    self.feature_1 = content.feature_settings[:feature_1] if self.has_attribute?(:feature_1) && self.feature_1.nil?
    self.feature_2 = content.feature_settings[:feature_2] if self.has_attribute?(:feature_2) && self.feature_2.nil?

    if !content.setting_value(:basic_setting).blank?
      self.layout_id ||= content.setting_extra_value(:basic_setting, :default_layout_id).to_i
      self.concept_id ||= content.setting_value(:basic_setting).to_i
    elsif (node = content.public_node)
      self.layout_id ||= node.layout_id
      self.concept_id ||= node.concept_id
    else
      self.concept_id ||= content.concept_id
    end
  end

  def set_display_attributes
    self.update_column(:display_published_at, self.published_at) unless self.display_published_at
    self.update_column(:display_updated_at, self.updated_at) if self.display_updated_at.blank? || !self.keep_display_updated_at
  end

  def set_serial_no
    return if self.serial_no.present?
    seq = Util::Sequencer.next_id('gp_article_doc_serial_no', :version => self.content_id)
    self.serial_no = seq
  end

  def node_existence
    unless content.doc_node
      case state
      when 'public'
        errors.add(:base, '記事コンテンツのディレクトリが作成されていないため、即時公開が行えません。')
      when 'approvable'
        errors.add(:base, '記事コンテンツのディレクトリが作成されていないため、承認依頼が行えません。')
      end
    end
  end

  def validate_platform_dependent_characters
    [:title, :body, :mobile_title, :mobile_body].each do |attr|
      if chars = Util::String.search_platform_dependent_characters(send(attr))
        errors.add attr, :platform_dependent_characters, :chars => chars
      end
    end
  end

  def make_file_contents_path_relative
    self.body = self.body.gsub(%r!("|')[^"'(]*?/(file_contents/)!, '\1\2') if self.body.present?
    self.mobile_body = self.mobile_body.gsub(%r!("|')[^"'(]*?/(file_contents/)!, '\1\2') if self.mobile_body.present?
  end

  def event_dates_range
    return if self.event_started_on.blank? && self.event_ended_on.blank?
    self.event_started_on = self.event_ended_on if self.event_started_on.blank?
    self.event_ended_on = self.event_started_on if self.event_ended_on.blank?
    errors.add(:event_ended_on, "が#{self.class.human_attribute_name :event_started_on}を過ぎています。") if self.event_ended_on < self.event_started_on
  end

  def extract_links(html, all)
    links = Nokogiri::HTML.parse(html).css('a[@href]').map {|a| {body: a.text, url: a.attribute('href').value} }
    return links if all
    links.select do |link|
      uri = URI.parse(link[:url])
      next true unless uri.absolute?
      [URI::HTTP, URI::HTTPS, URI::FTP].include?(uri.class)
    end
  rescue => evar
    warn_log evar.message
    return []
  end

  def check_links(links)
    links.map{|link|
      uri = URI.parse(link[:url])
      url = unless uri.absolute?
              next unless uri.path =~ /^\//
              "#{content.site.full_uri.sub(/\/$/, '')}#{uri.path}"
            else
              uri.to_s
            end

      res = Util::LinkChecker.check_url(url)
      {body: link[:body], url: url, status: res[:status], reason: res[:reason], result: res[:result]}
    }.compact
  end

  def broken_link_existence
    errors.add(:base, 'リンクチェック結果を確認してください。') if broken_link_exists?
  end

  def save_links
    lib = links_in_body
    links.each do |link|
      link.destroy unless lib.detect {|l| l[:body] == link.body && l[:url] == link.url }
    end
    lib.each do |link|
      links.create(body: link[:body], url: link[:url]) unless links.where(body: link[:body], url: link[:url]).first
    end
  end

  def publish_qrcode
    return true unless self.state_public?
    return true unless self.qrcode_visible?
    Util::Qrcode.create(self.public_full_uri, self.qrcode_path)
    return true
  end

  def validate_accessibility_check
    return unless Zomeki.config.application['cms.enable_accessibility_check']
    check_results = Util::AccessibilityChecker.check body

    if check_results != [] && !ignore_accessibility_check
     errors.add(:base, 'アクセシビリティチェック結果を確認してください')
    end
  end

  def body_limit_for_mobile
    limit = Zomeki.config.application['gp_article.body_limit_for_mobile'].to_i
    current_size = self.body_for_mobile.bytesize
    if current_size > limit
      target = self.mobile_body.present? ? :mobile_body : :body
      errors.add(target, "が携帯向け容量制限#{limit}バイトを超えています。（現在#{current_size}バイト）")
    end
  end

  def replace_public
    return if !state_public? || prev_edition.nil? || prev_edition.state_archived?

    prev_edition.update_column(:state, 'archived')
    self.comments = prev_edition.comments

    if (pe = prev_editions).size > 4 # Include self
      pe.last.destroy
    end
  end

  def keep_edition_relation
    next_edition.update_column(:prev_edition_id, prev_edition_id) if next_edition
    return true
  end
end
