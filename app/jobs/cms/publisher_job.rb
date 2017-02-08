class Cms::PublisherJob < ApplicationJob
  queue_as :cms_publisher
  queue_with_priority 20

  def perform
    loop_count = 0
    while Cms::Publisher.exists? && (loop_count += 1) <= 1000
      publishers = Cms::Publisher.order(:priority, :id).limit(10).all
      break if publishers.blank?
  
      publishers.update_all(state: 'performing')

      publisher_map = publishers.group_by(&:publishable_type)
      publisher_map.each do |pub_type, pubs|
        pub_model = pub_type.gsub(/(\w+::)(\w+)/, '\\1Publisher::\\2').constantize
        pub_model.perform_publish(pubs)
        pubs.each(&:destroy)
      end
    end
  end
end
