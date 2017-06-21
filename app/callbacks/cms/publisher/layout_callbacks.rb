class Cms::Publisher::LayoutCallbacks < PublisherCallbacks
  def enqueue(layout)
    @layout = layout
    return unless enqueue?
    enqueue_nodes
    enqueue_categories
    enqueue_organization_groups
    enqueue_docs
  end

  private

  def enqueue?
    return unless super
    @layout.name.present?
  end

  def enqueue_nodes
    nodes = Cms::Node.public_state.where(layout_id: @layout.id)
    Cms::Publisher.register(@layout.site_id, nodes)
  end

  def enqueue_categories
    cat_types = GpCategory::CategoryType.public_state.where(layout_id: @layout.id).all
    cat_types.each do |cat_type|
      Cms::Publisher.register(@layout.site_id, cat_type.public_categories)
    end

    cats = GpCategory::Category.public_state.where(layout_id: @layout.id)
    Cms::Publisher.register(@layout.site_id, cats)
  end

  def enqueue_organization_groups
    ogs = Organization::Group.public_state.with_layout(@layout.id)
    Cms::Publisher.register(@layout.site_id, ogs)
  end

  def enqueue_docs
    docs = GpArticle::Doc.public_state.where(layout_id: @layout.id).select(:id)
    Cms::Publisher.register(@layout.site_id, docs)
  end
end
