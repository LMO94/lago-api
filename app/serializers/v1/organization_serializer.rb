# frozen_string_literal: true

module V1
  class OrganizationSerializer < ModelSerializer
    def serialize
      payload = {
        lago_id: model.id,
        name: model.name,
        created_at: model.created_at.iso8601,
        webhook_url: model.webhook_url,
        country: model.country,
        address_line1: model.address_line1,
        address_line2: model.address_line2,
        state: model.state,
        zipcode: model.zipcode,
        email: model.email,
        city: model.city,
        legal_name: model.legal_name,
        legal_number: model.legal_number,
        timezone: model.timezone,
        email_settings: model.email_settings,
        tax_identification_number: model.tax_identification_number,
        billing_configuration:,
      }.merge(legacy_values.except(:billing_configuration))

      payload = payload.merge(taxes) if include?(:taxes)

      payload
    end

    private

    def billing_configuration
      {
        invoice_footer: model.invoice_footer,
        invoice_grace_period: model.invoice_grace_period,
        document_locale: model.document_locale,
      }.merge(legacy_values[:billing_configuration])
    end

    def legacy_values
      @legacy_values ||= ::V1::Legacy::OrganizationSerializer.new(model).serialize
    end

    def taxes
      ::CollectionSerializer.new(
        model.taxes.applied_to_organization,
        ::V1::TaxSerializer,
        collection_name: 'taxes',
      ).serialize
    end
  end
end
