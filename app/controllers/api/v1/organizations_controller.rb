# frozen_string_literal: true

module Api
  module V1
    class OrganizationsController < Api::BaseController
      def update
        result = Organizations::UpdateService.call(organization: current_organization, params: input_params)

        if result.success?
          render(
            json: ::V1::OrganizationSerializer.new(
              result.organization,
              root_name: 'organization',
              includes: %i[taxes],
            ),
          )
        else
          render_error_response(result)
        end
      end

      private

      def input_params
        params.require(:organization).permit(
          :webhook_url,
          :country,
          :address_line1,
          :address_line2,
          :state,
          :zipcode,
          :email,
          :city,
          :legal_name,
          :legal_number,
          :tax_identification_number,
          :timezone,
          email_settings: [],
          billing_configuration: [
            :invoice_footer,
            :invoice_grace_period,
            :document_locale,

            # NOTE(legacy): vat has been moved to tax model
            :vat_rate,
          ],
        )
      end
    end
  end
end
