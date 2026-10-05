# Changelog

## [0.10.0](https://github.com/bubbacore/jenny/compare/v0.9.0...v0.10.0) (2026-10-05)


### ⚠ BREAKING CHANGES

* **catalog:** the movie slug comes from the original title instead of the title in Brazil, and existing slugs are rewritten.

### Features

* **catalog:** derive the movie address from the original title ([fc190ec](https://github.com/bubbacore/jenny/commit/fc190ecf795365786436f1487bc0e989cf447a9a))

## [0.9.0](https://github.com/bubbacore/jenny/compare/v0.8.0...v0.9.0) (2026-10-05)


### ⚠ BREAKING CHANGES

* **ingestion:** an ok reading of the official site must carry post or no_new_post, and only it may carry them.

### Features

* **ingestion:** remember read posts and reuse them without a new post ([89e05f1](https://github.com/bubbacore/jenny/commit/89e05f1983ce600980106004cbc317e5d023466b))

## [0.8.0](https://github.com/bubbacore/jenny/compare/v0.7.0...v0.8.0) (2026-10-05)


### Features

* **ingestion:** keep pending ticket types and resolve them ([2b59973](https://github.com/bubbacore/jenny/commit/2b5997389aae7849d22e6753d3d8790628796748))

## [0.7.0](https://github.com/bubbacore/jenny/compare/v0.6.0...v0.7.0) (2026-10-05)


### Features

* **ingestion:** choose movie values by source reliability ([55d9967](https://github.com/bubbacore/jenny/commit/55d99674f3317605587a907e20c99e6312829735))

## [0.6.0](https://github.com/bubbacore/jenny/compare/v0.5.0...v0.6.0) (2026-10-05)


### Features

* **ingestion:** add the catalog with people, credits, images and trailer ([9dc694d](https://github.com/bubbacore/jenny/commit/9dc694dd70c0f5940e7f89dba0bef0aedad282ca))

## [0.5.0](https://github.com/bubbacore/jenny/compare/v0.4.0...v0.5.0) (2026-10-03)


### Features

* **ingestion:** add pending identification and its resolution ([e569574](https://github.com/bubbacore/jenny/commit/e5695748d83e198664460d5d260489e0eddaf05f))

## [0.4.0](https://github.com/bubbacore/jenny/compare/v0.3.0...v0.4.0) (2026-10-03)


### ⚠ BREAKING CHANGES

* **ingestion:** start-reading requires collection_id, and collection-plan refuses chosen cinemas in a daily collection and requires them in a recollection.

### Features

* **ingestion:** add collections, automatic publication and summaries ([be8327b](https://github.com/bubbacore/jenny/commit/be8327b47ab5fddedd2f61a19024ef4c893a1d62))

## [0.3.0](https://github.com/bubbacore/jenny/compare/v0.2.0...v0.3.0) (2026-10-02)


### Features

* **ingestion:** record failed readings and the state of each day ([021e992](https://github.com/bubbacore/jenny/commit/021e99271f354b5b895c484ca29dc91af0619ae2))

## [0.2.0](https://github.com/bubbacore/jenny/compare/v0.1.0...v0.2.0) (2026-10-02)


### Features

* **ingestion:** publish the reading contract ([9651c54](https://github.com/bubbacore/jenny/commit/9651c54bb4ef1b5c6fffdcb92a84a537cd28e688))
* **ingestion:** reserve a cinema and record a successful reading ([5976922](https://github.com/bubbacore/jenny/commit/5976922f85b5a6a15f8936d4a5798e6a364855d1))
* **ingestion:** reserve a cinema and record a successful reading ([8ee7d1f](https://github.com/bubbacore/jenny/commit/8ee7d1f7d0f9a64a28d9337dd3d801543b4e430a))

## 0.1.0 (2026-10-02)


### Features

* add the v1 registry, closed database and collection plan ([0aedb12](https://github.com/bubbacore/jenny/commit/0aedb12f791c6073ca42f7b374ea873d148f19e4))
* **db:** add addresses, Instagram and sites of the v1 cinemas ([1f46476](https://github.com/bubbacore/jenny/commit/1f46476daf154c3e45f90573ac5cd9c1360e8f8f))
* **db:** add cities, chains, cinemas and sources ([08943d0](https://github.com/bubbacore/jenny/commit/08943d0a0109575199159eb66267c2deaa430a7f))
* **db:** add contact details and names of the v1 cinemas ([d8dfc8a](https://github.com/bubbacore/jenny/commit/d8dfc8a5569bf60d538af240d21422fdd2b957a0))
* **db:** add popular and official cinema names ([a23b92b](https://github.com/bubbacore/jenny/commit/a23b92b277e60553ee44958fedbd6f5be033d1a5))
* **db:** add the v1 registry ([846e8cb](https://github.com/bubbacore/jenny/commit/846e8cbab8e0af36c7989926d2faabaf37e66704))
* **db:** close the database to public reads ([ed47ec3](https://github.com/bubbacore/jenny/commit/ed47ec3b60c74221fb8d47cfca47e41e69a5176d))
* **ingestion:** serve the collection plan to the Hermes ([847407e](https://github.com/bubbacore/jenny/commit/847407e6a28dea774cc754f7e29b5d0d9dca5357))
