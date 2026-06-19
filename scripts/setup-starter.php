<?php

declare(strict_types=1);

use craft\ckeditor\Field as CkeditorField;
use craft\fs\Local;
use craft\models\Volume;
use verbb\navigation\models\Nav;
use verbb\navigation\models\Nav_SiteSettings;
use verbb\navigation\Navigation;

$messages = [];

$filesystem = Craft::$app->getFs()->getFilesystemByHandle('assets');
if ($filesystem === null) {
    $filesystem = new Local([
        'name' => 'Assets',
        'handle' => 'assets',
        'hasUrls' => true,
        'url' => '@web/uploads',
        'path' => '@webroot/uploads',
    ]);

    if (!Craft::$app->getFs()->saveFilesystem($filesystem)) {
        throw new RuntimeException('Could not create Assets filesystem: ' . json_encode($filesystem->getErrors()));
    }
    $messages[] = 'Created the Assets filesystem.';
}

$volume = Craft::$app->getVolumes()->getVolumeByHandle('assets');
if ($volume === null) {
    $volume = new Volume([
        'name' => 'Assets',
        'handle' => 'assets',
        'fs' => 'assets',
    ]);

    if (!Craft::$app->getVolumes()->saveVolume($volume)) {
        throw new RuntimeException('Could not create Assets volume: ' . json_encode($volume->getErrors()));
    }
    $messages[] = 'Created the Assets volume.';
}

$bodyField = Craft::$app->getFields()->getFieldByHandle('body');
if ($bodyField === null) {
    $bodyField = new CkeditorField([
        'name' => 'Body',
        'handle' => 'body',
        'toolbar' => [
            'heading', '|', 'bold', 'italic', 'link', '|',
            'bulletedList', 'numberedList', 'blockQuote', '|',
            'insertImage', 'insertTable', '|', 'undo', 'redo',
        ],
        'headingLevels' => [2, 3, 4],
        'availableVolumes' => [$volume->uid],
        'defaultUploadLocationVolume' => $volume->uid,
        'showWordCount' => true,
    ]);

    if (!Craft::$app->getFields()->saveField($bodyField)) {
        throw new RuntimeException('Could not create Body field: ' . json_encode($bodyField->getErrors()));
    }
    $messages[] = 'Created the Body CKEditor field.';
}

$navigation = Navigation::$plugin->getNavs()->getNavByHandle('mainNavigation');
if ($navigation === null) {
    $navigation = new Nav([
        'name' => 'Main Navigation',
        'handle' => 'mainNavigation',
        'instructions' => 'Primary site navigation.',
        'propagationMethod' => Nav::PROPAGATION_METHOD_ALL,
        'maxLevels' => 2,
    ]);

    $siteSettings = [];
    foreach (Craft::$app->getSites()->getAllSites() as $site) {
        $siteSettings[$site->id] = new Nav_SiteSettings([
            'siteId' => $site->id,
            'enabled' => true,
        ]);
    }
    $navigation->setSiteSettings($siteSettings);

    if (!Navigation::$plugin->getNavs()->saveNav($navigation)) {
        throw new RuntimeException('Could not create Main Navigation: ' . json_encode($navigation->getErrors()));
    }
    $messages[] = 'Created Main Navigation.';
}

return $messages === []
    ? 'Starter content infrastructure already exists.'
    : implode(PHP_EOL, $messages);
