module MailyHerald
  # Stores information about email delivery to entity.
  #
  # It is associated with entity object and {Dispatch}.
  # Log can have following statuses:
  # - +scheduled+ - email hasn't been processed yet,
  # - +delivered+ - email was sent to entity,
  # - +skipped+ - email deliver was skipped (i.e. due to conditions not met),
  # - +error+ - there was an error during email delivery.
  #
  # @attr [Fixnum]    entity_id      Entity association id.
  # @attr [String]    entity_type    Entity association type.
  # @attr [String]    entity_email   Delivery email. Stored in case associated entity gets deleted.
  # @attr [Fixnum]    mailing_id     {Dispatch} association id.
  # @attr [Sumbol]    status         
  # @attr [Hash]      data           Custom log data.
  # @attr [DateTime]  processing_at  Timestamp of {Dispatch} processing.
  #                                  Can be either future (when in +scheduled+ state) or past.
  class Log < ApplicationRecord
    AVAILABLE_STATUSES = [:scheduled, :delivered, :skipped, :error]

    belongs_to  :entity,        polymorphic: true
    belongs_to  :mailing,       class_name: "MailyHerald::Dispatch", foreign_key: :mailing_id

    validates   :entity,        presence: true
    validates   :mailing,       presence: true
    validates   :status,        presence: true, inclusion: {in: AVAILABLE_STATUSES}

    validates   :processing_at, presence: true, if: :scheduled?

    scope       :ordered,       lambda { order("processing_at asc") }
    scope       :for_entity,    lambda {|entity| where(entity_id: entity.id, entity_type: entity.class.base_class.name) }
    scope       :for_mailing,   lambda {|mailing| where(mailing_id: mailing.id) }
    scope       :for_mailings,  lambda {|mailings| where("mailing_id in (?)", mailings) }
    scope       :delivered,     lambda { where(status: :delivered) }
    scope       :skipped,       lambda { where(status: :skipped) }
    scope       :error,         lambda { where(status: :error) }
    scope       :scheduled,     lambda { where(status: :scheduled) }
    scope       :processed,     lambda { where(status: [:delivered, :skipped, :error]) }
    scope       :not_skipped,   lambda { where("status != 'skipped'") }
    scope       :like_email,    lambda {|query| where("maily_herald_logs.entity_email LIKE (?)", "%#{query}%") }

    serialize   :data,          Hash

    before_create :set_token

    # Contains `Mail::Message` object that was delivered.
    #
    # Present only in logs of state `delivered` and obtained via
    # `Mailing.run` method.
    attr_accessor :mail

    # Creates Log object for given {Dispatch} and entity.
    #
    # @param mailing [Dispatch]
    # @param entity [ActiveRecord::Base]
    # @param attributes [Hash] log attributes
    # @option attributes [Time] :processing_at (DateTime.now)
    # @option attributes [Symbol] :status
    # @option attributes [Hash] :data
    def self.create_for mailing, entity, attributes = {}
      log = Log.new
      log.set_attributes_for mailing, entity, attributes
      log.save!
      log
    end

    def self.get_from(entity)
      if entity.has_attribute?(:maily_log_id) && entity.maily_log_id
        log = MailyHerald::Log.new

        entity.attributes.each do |k, v|
          if match = k.match(/^maily_log_(\w+)$/)
            log.instance_variable_get(:@attributes).write_from_database(match[1], v)
          end
        end

        log.readonly!
        log
      end
    end

    # Sets Log instance attributes.
    #
    # @param mailing [Dispatch]
    # @param entity [ActiveRecord::Base]
    # @param attributes [Hash] log attributes
    # @option attributes [Time] :processing_at (DateTime.now)
    # @option attributes [Symbol] :status
    # @option attributes [Hash] :data
    def set_attributes_for mailing, entity, attributes = {}
      self.mailing = mailing
      self.entity = entity
      self.entity_email = mailing.destination(entity)

      self.processing_at = attributes[:processing_at] || DateTime.now
      self.status = attributes[:status]
      self.data = attributes[:data]
    end

    def status
      read_attribute(:status).to_sym
    end

    def delivered?
      self.status == :delivered
    end

    def skipped?
      self.status == :skipped
    end

    def error?
      self.status == :error
    end

    def scheduled?
      self.status == :scheduled
    end

    def processed?
      [:delivered, :skipped, :error].include?(self.status)
    end

    # Set attributes of a schedule so it has 'skipped' status.
    def skip reason
      if self.status == :scheduled
        self.status = :skipped
        self.data[:skip_reason] = reason
        true
      end
    end

    # Set attributes of a schedule so it is postponed.
    def postpone_delivery
      if !self.data[:delivery_attempts] || self.data[:delivery_attempts].length < 3
        self.data[:original_processing_at] ||= self.processing_at
        self.data[:delivery_attempts] ||= []
        self.data[:delivery_attempts].push(date_at: Time.now, action: :postpone, reason: :not_processable)
        self.processing_at = Time.now + 1.day
        true
      end
    end

    def postponed_delivery_attempts
      if self.data[:delivery_attempts] && self.data[:delivery_attempts].any?
        self.data[:delivery_attempts].select { |da| da[:action] == :postpone }
      else
        []
      end
    end

    # Set attributes of a schedule so it has 'delivered' status.
    # @param options Various options like 'content', 'opened_at' or 'ip_addresses'.
    def deliver options = {}
      self.status = :delivered
      options.each {|k,v| self.data[k] = v }
    end

    # Set attributes of a schedule so it has 'error' status.
    # @param msg Error description.
    def error msg
      self.status = :error
      self.data[:msg] = msg
    end

    def preview
      mail =  if self.delivered?
                ::Mail.new(self.data[:content])
              else
                self.mailing.build_mail self
              end

      @preview ||= MailyHerald::Mailing::Preview.new mail
    end

    def delivery_attempts
      @delivery_attempts = MailyHerald::Log::DeliveryAttempts.new self.data
    end

    # Retry sending email - changing 'status' to 'scheduled.
    def retry
      if self.error?
        self.data[:delivery_attempts] ||= []
        self.data[:delivery_attempts].push(date_at: Time.now, action: :retry, reason: :error, msg: self.data[:msg])
        self.data[:msg] = nil
        self.data[:content] = nil
        self.status = :scheduled
        self.save!
      end
    end

    private

    def set_token
      self.token = SecureRandom.urlsafe_base64(32).gsub(/[\-_]/, "").first(32)
    end
  end
end
