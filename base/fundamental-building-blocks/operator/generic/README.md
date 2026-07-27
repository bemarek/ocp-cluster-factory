This block requires that in the overlay using it, a configMapGenerator must be used to generate operator-parameters configMap with these parameters:

required:
    namespace
    SubscriptionName
    OperatorGroupName
    channel
    source
optional:
    installPlanApproval (default=Automatic)
